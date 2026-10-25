/* =====================================================================
   QUÍMICA ANDINA S.A.S. (ficticia) — Script 05: PROPUESTAS DE PRECIOS
   Requiere qa_01_esquema.sql. Se puede ejecutar varias veces.
   ---------------------------------------------------------------------
   Una "propuesta de precios" (PP) es el documento informativo que genera
   el cotizador. NO es la cotización formal: esa se emite en el ERP.
   Cada PP tiene consecutivo propio (PP-2026-0001) y se puede enlazar a
   la cotización formal (CTZ-…) para medir:  PP → cotización → pedido.
   ===================================================================== */
SET search_path TO qa, public;

INSERT INTO parametros VALUES
 ('vigencia_propuesta_dias', '8', 'Días de vigencia de una propuesta de precios (PP)')
ON CONFLICT (clave) DO NOTHING;

-- Consecutivos por serie y año (atómico, sin huecos por concurrencia)
CREATE TABLE IF NOT EXISTS consecutivos (
    serie   VARCHAR(5) NOT NULL,
    anio    INTEGER    NOT NULL,
    ultimo  INTEGER    NOT NULL,
    PRIMARY KEY (serie, anio)
);

CREATE TABLE IF NOT EXISTS propuestas (
    numero_propuesta         VARCHAR(20)  PRIMARY KEY,          -- PP-2026-0001
    fecha                    DATE         NOT NULL DEFAULT CURRENT_DATE,
    vigente_hasta            DATE         NOT NULL,
    cliente_id               VARCHAR(20)  NOT NULL REFERENCES clientes(cliente_id),
    vendedor_id              VARCHAR(20)  REFERENCES vendedores(vendedor_id),
    valor_subtotal           NUMERIC(16,2),
    numero_cotizacion_erp  VARCHAR(30),                       -- se llena al formalizar
    fecha_formalizacion      DATE,
    observaciones            TEXT,
    creado_en                TIMESTAMP    NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS propuestas_detalle (
    numero_propuesta  VARCHAR(20)   NOT NULL REFERENCES propuestas(numero_propuesta) ON DELETE CASCADE,
    linea             INTEGER       NOT NULL,
    producto_id       VARCHAR(20)   NOT NULL REFERENCES productos(producto_id),
    cantidad          NUMERIC(14,3) NOT NULL CHECK (cantidad > 0),
    precio_unitario   NUMERIC(16,2),
    origen_precio     VARCHAR(20),
    valor             NUMERIC(16,2),
    entrega           TEXT,
    PRIMARY KEY (numero_propuesta, linea)
);
CREATE INDEX IF NOT EXISTS ix_prop_cliente ON propuestas (cliente_id, fecha);

/* ---------------------------------------------------------------------
   Registra una propuesta y devuelve su número.
   p_lineas: JSON con [{"producto_id","cantidad","precio","origen","entrega"}, …]
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_registrar_propuesta(
        p_cliente   VARCHAR,
        p_vendedor  VARCHAR,
        p_lineas    JSONB,
        p_obs       TEXT DEFAULT NULL)
RETURNS VARCHAR
LANGUAGE plpgsql AS $$
DECLARE
  v_anio   INT := extract(year FROM CURRENT_DATE);
  v_n      INT;
  v_numero VARCHAR;
BEGIN
  IF jsonb_array_length(coalesce(p_lineas, '[]'::jsonb)) = 0 THEN
    RAISE EXCEPTION 'La propuesta no tiene productos';
  END IF;

  INSERT INTO qa.consecutivos (serie, anio, ultimo) VALUES ('PP', v_anio, 1)
  ON CONFLICT (serie, anio) DO UPDATE SET ultimo = qa.consecutivos.ultimo + 1
  RETURNING ultimo INTO v_n;
  v_numero := 'PP-' || v_anio || '-' || lpad(v_n::text, 4, '0');

  INSERT INTO qa.propuestas (numero_propuesta, fecha, vigente_hasta, cliente_id, vendedor_id, observaciones)
  VALUES (v_numero, CURRENT_DATE, CURRENT_DATE + qa.fn_parametro_int('vigencia_propuesta_dias'),
          p_cliente, (SELECT vendedor_id FROM qa.vendedores WHERE vendedor_id = p_vendedor), p_obs);

  INSERT INTO qa.propuestas_detalle (numero_propuesta, linea, producto_id, cantidad, precio_unitario,
                                     origen_precio, valor, entrega)
  SELECT v_numero, x.ord::int, qa.fn_codigo(x.l->>'producto_id'), (x.l->>'cantidad')::numeric,
         (x.l->>'precio')::numeric, x.l->>'origen',
         round((x.l->>'cantidad')::numeric * (x.l->>'precio')::numeric, 0), x.l->>'entrega'
  FROM jsonb_array_elements(p_lineas) WITH ORDINALITY AS x(l, ord);

  UPDATE qa.propuestas SET valor_subtotal = (SELECT sum(valor) FROM qa.propuestas_detalle
                                             WHERE numero_propuesta = v_numero)
  WHERE numero_propuesta = v_numero;
  RETURN v_numero;
END $$;

/* ---------------------------------------------------------------------
   Enlaza una propuesta con la cotización formal del ERP
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_formalizar_propuesta(p_propuesta VARCHAR, p_cotizacion VARCHAR)
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE qa.propuestas
  SET numero_cotizacion_erp = upper(btrim(p_cotizacion)), fecha_formalizacion = CURRENT_DATE
  WHERE numero_propuesta = p_propuesta;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la propuesta %', p_propuesta; END IF;
END $$;

/* ---------------------------------------------------------------------
   Vistas
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_propuestas AS
SELECT p.numero_propuesta, p.fecha, p.vigente_hasta, p.cliente_id, c.nombre AS cliente,
       p.vendedor_id, v.nombre AS vendedor, p.valor_subtotal,
       p.numero_cotizacion_erp, p.fecha_formalizacion,
       ct.estado_erp AS estado_cotizacion,
       CASE WHEN ct.estado_erp = 'PEDIDA'           THEN 'GANADA'
            WHEN p.numero_cotizacion_erp IS NOT NULL THEN 'FORMALIZADA'
            WHEN p.vigente_hasta < CURRENT_DATE        THEN 'VENCIDA'
            ELSE 'VIGENTE' END                         AS estado,
       p.fecha_formalizacion - p.fecha                 AS dias_a_formalizar
FROM propuestas p
JOIN clientes c USING (cliente_id)
LEFT JOIN vendedores v ON v.vendedor_id = p.vendedor_id
LEFT JOIN cotizaciones ct ON ct.numero_cotizacion = p.numero_cotizacion_erp;

-- Embudo mensual: propuestas → formalizadas en el ERP → ganadas (pedido)
CREATE OR REPLACE VIEW v_embudo_propuestas AS
SELECT date_trunc('month', fecha)::date AS mes, vendedor_id,
       count(*)                                                        AS propuestas,
       count(*) FILTER (WHERE estado IN ('FORMALIZADA','GANADA'))      AS formalizadas,
       count(*) FILTER (WHERE estado = 'GANADA')                       AS ganadas,
       round(100.0 * count(*) FILTER (WHERE estado IN ('FORMALIZADA','GANADA')) / count(*), 1) AS pct_formalizadas,
       round(avg(dias_a_formalizar), 1)                                AS dias_promedio_a_formalizar,
       sum(valor_subtotal)                                             AS valor_propuesto
FROM v_propuestas
GROUP BY 1, 2;
