/* =====================================================================
   QUÍMICA ANDINA S.A.S. (ficticia) — Script 10: BASE PARA EL FORECAST
   Requiere qa_04_carga.sql (versión oct-2026). Se puede ejecutar varias veces.
   ---------------------------------------------------------------------
   1. qa.v_forecast_cliente_mes  → ventas mensuales por cliente REAL y producto
                                   (une NIT antiguo + NIT nuevo y variantes "E")
   2. qa.v_posibles_sucesores    → sugiere clientes que parecen el mismo negocio
                                   con NIT nuevo, para que una persona confirme
   3. qa.pr_enlazar_sucesor(...) → (ya existe en qa_04) registra la confirmación
   ===================================================================== */

-- 1) Ventas mensuales por cliente real y producto -------------------------
CREATE OR REPLACE VIEW qa.v_forecast_cliente_mes AS
SELECT date_trunc('month', v.fecha)::date AS mes,
       c.cliente_vigente                  AS cliente_id,       -- NIT antiguo y nuevo = un solo cliente
       v.producto_agrupado                AS producto_id,      -- variante "E" = su producto base
       sum(v.cantidad)                    AS cantidad,
       sum(v.valor_subtotal)              AS valor,
       count(DISTINCT v.numero_factura) FILTER (WHERE v.tipo = 'FV') AS facturas
FROM qa.v_ventas v
JOIN qa.v_clientes_consolidado c USING (cliente_id)
GROUP BY 1, 2, 3;
COMMENT ON VIEW qa.v_forecast_cliente_mes IS
  'Base del forecast por cliente: un cliente que cambió de NIT aparece con toda su historia bajo el NIT vigente.';

-- 2) Posibles cambios de NIT ----------------------------------------------
-- Pares que una persona ya revisó y descartó (no son el mismo negocio): no se vuelven a sugerir
CREATE TABLE IF NOT EXISTS qa.sucesores_descartados (
    nit_antiguo  VARCHAR(20) NOT NULL,
    nit_nuevo    VARCHAR(20) NOT NULL,
    descartado_en TIMESTAMP  NOT NULL DEFAULT now(),
    PRIMARY KEY (nit_antiguo, nit_nuevo)
);
CREATE OR REPLACE PROCEDURE qa.pr_descartar_sucesor(p_antiguo VARCHAR, p_nuevo VARCHAR)
LANGUAGE sql AS $$
  INSERT INTO qa.sucesores_descartados (nit_antiguo, nit_nuevo) VALUES (p_antiguo, p_nuevo)
  ON CONFLICT DO NOTHING;
$$;

-- Nombre "base": sin tipo de sociedad ni signos, para comparar
CREATE OR REPLACE FUNCTION qa.fn_nombre_base(p TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT btrim(regexp_replace(
           regexp_replace(upper(translate(coalesce(p, ''), 'áéíóúÁÉÍÓÚñÑ.,', 'aeiouAEIOUnN  ')),
                          '\m(S ?A ?S|SAS|S ?A|SA|LTDA|LIMITADA|E ?U|EU|S ?EN ?C|Y CIA|CIA)\M', ' ', 'g'),
           '\s+', ' ', 'g'));
$$;

CREATE OR REPLACE VIEW qa.v_posibles_sucesores AS
WITH compras AS (
  SELECT cliente_id, min(fecha) AS primera, max(fecha) AS ultima, count(DISTINCT numero_factura) AS facturas
  FROM qa.v_ventas WHERE tipo = 'FV' GROUP BY 1),
prods AS (SELECT DISTINCT cliente_id, producto_agrupado AS p FROM qa.v_ventas WHERE tipo = 'FV'),
-- "nuevo": NIT que empezó a comprar (o fue creado) en los últimos 120 días
nuevos AS (
  SELECT c.cliente_id, c.nombre, c.ciudad, coalesce(k.primera, CURRENT_DATE) AS primera
  FROM qa.clientes c LEFT JOIN compras k USING (cliente_id)
  WHERE c.estado <> 'INACTIVO' AND coalesce(k.primera, CURRENT_DATE) >= CURRENT_DATE - 120
    AND NOT EXISTS (SELECT 1 FROM qa.clientes x WHERE x.cliente_sucesor = c.cliente_id)),
-- "antiguo": cliente con historia que dejó de comprar, sin sucesor registrado
antiguos AS (
  SELECT c.cliente_id, c.nombre, c.ciudad, k.ultima, k.facturas
  FROM qa.clientes c JOIN compras k USING (cliente_id)
  WHERE c.cliente_sucesor IS NULL AND k.facturas >= 3),
pares AS (
  SELECT a.cliente_id AS nit_antiguo, a.nombre AS nombre_antiguo, a.ultima AS ultima_compra_antiguo,
         n.cliente_id AS nit_nuevo,   n.nombre AS nombre_nuevo,   n.primera AS primera_compra_nuevo,
         qa.fn_nombre_base(a.nombre) = qa.fn_nombre_base(n.nombre)                    AS mismo_nombre,
         position(qa.fn_nombre_base(a.nombre) IN qa.fn_nombre_base(n.nombre)) > 0
           OR position(qa.fn_nombre_base(n.nombre) IN qa.fn_nombre_base(a.nombre)) > 0 AS nombre_contenido,
         a.ciudad IS NOT DISTINCT FROM n.ciudad                                        AS misma_ciudad,
         (SELECT count(*) FROM prods x JOIN prods y ON y.p = x.p AND y.cliente_id = n.cliente_id
          WHERE x.cliente_id = a.cliente_id)                                           AS productos_comunes,
         (SELECT count(*) FROM prods y WHERE y.cliente_id = n.cliente_id)              AS productos_nuevo
  FROM antiguos a JOIN nuevos n ON n.cliente_id <> a.cliente_id
  WHERE n.primera >= a.ultima - 30                      -- el nuevo aparece cuando el antiguo se apaga
    AND n.primera <= a.ultima + 180)
SELECT nit_antiguo, nombre_antiguo, ultima_compra_antiguo, nit_nuevo, nombre_nuevo, primera_compra_nuevo,
       productos_comunes,
       ( CASE WHEN mismo_nombre THEN 60 WHEN nombre_contenido THEN 40 ELSE 0 END
       + CASE WHEN misma_ciudad THEN 15 ELSE 0 END
       + CASE WHEN productos_nuevo > 0
              THEN round(25.0 * productos_comunes / productos_nuevo) ELSE 0 END )::int AS coincidencia_pct
FROM pares
WHERE (mismo_nombre OR nombre_contenido)
  AND NOT EXISTS (SELECT 1 FROM qa.sucesores_descartados d
                  WHERE d.nit_antiguo = pares.nit_antiguo AND d.nit_nuevo = pares.nit_nuevo)
ORDER BY coincidencia_pct DESC;
COMMENT ON VIEW qa.v_posibles_sucesores IS
  'Sugerencias (no decisiones). Mismo negocio: CALL qa.pr_enlazar_sucesor(antiguo, nuevo). No lo es: CALL qa.pr_descartar_sucesor(antiguo, nuevo).';
