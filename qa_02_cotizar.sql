/* =====================================================================
   QUÍMICA ANDINA S.A.S. (ficticia) — Script 02: función de COTIZACIÓN CON CANTIDADES
   Requiere qa_01_esquema.sql. Se puede ejecutar varias veces.
   ---------------------------------------------------------------------
   Uso:
     SELECT * FROM qa.fn_cotizar(
         '900111002',                 -- cliente (NIT)
         ARRAY['42','7','61'],        -- productos (códigos)
         ARRAY[50, 5, 200]);          -- cantidades, en el mismo orden
   Devuelve una fila por producto y una fila final con el TOTAL.
   ===================================================================== */
SET search_path TO qa, public;

CREATE OR REPLACE FUNCTION fn_cotizar(
        p_cliente     VARCHAR,
        p_productos   TEXT[],
        p_cantidades  NUMERIC[])
RETURNS TABLE (
        linea            INTEGER,
        producto_id      VARCHAR,
        producto         VARCHAR,
        cantidad         NUMERIC,
        precio_sugerido  NUMERIC,
        origen_precio    TEXT,
        precio_ultima_compra NUMERIC,
        valor_estimado   NUMERIC,
        disponible       NUMERIC,
        faltante         NUMERIC,
        entrega          TEXT,
        alertas          TEXT)
LANGUAGE sql STABLE AS
$$
WITH sol AS (
        SELECT t.n::int AS linea, qa.fn_codigo(t.p) AS producto_id, t.c AS cantidad
        FROM unnest(p_productos, p_cantidades) WITH ORDINALITY AS t(p, c, n)),
     r AS (
        SELECT * FROM qa.fn_cotizacion_rapida(p_cliente, p_productos)),
     det AS (
        SELECT s.linea,
               s.producto_id,
               r.producto,
               s.cantidad,
               coalesce(r.precio_especial, r.precio_lista)                           AS precio_sugerido,
               CASE WHEN r.precio_especial IS NOT NULL THEN 'ESPECIAL'
                    WHEN r.precio_lista    IS NOT NULL THEN 'LISTA ' || r.lista_cliente
                    ELSE 'SIN PRECIO' END                                             AS origen_precio,
               r.precio_ultima_compra,
               round(s.cantidad * coalesce(r.precio_especial, r.precio_lista), 0)    AS valor_estimado,
               r.disponible,
               greatest(s.cantidad - greatest(coalesce(r.disponible,0), 0), 0)       AS faltante,
               CASE WHEN r.producto IS NULL             THEN '—'
                    WHEN s.cantidad <= r.disponible     THEN 'Inmediata (almacén)'
                    WHEN s.cantidad <= greatest(r.disponible,0) + r.en_produccion
                                                        THEN 'Pocos días (se completa con producción)'
                    WHEN r.tipo = 'FABRICADO'           THEN 'Fabricar: aprox. ' ||
                                                             coalesce(r.tiempo_fabricacion_dias::text,'¿?') || ' días'
                    WHEN r.tipo = 'DISTRIBUIDO'         THEN 'Consultar a Compras'
                    ELSE 'Revisar disponibilidad' END                                 AS entrega,
               nullif(concat_ws(' | ',
                    CASE WHEN r.producto IS NULL   THEN 'Producto no existe en la base' END,
                    CASE WHEN s.cantidad IS NULL   THEN 'Falta la cantidad' END,
                    CASE WHEN s.cantidad < r.venta_minima
                         THEN 'Cantidad por debajo de la venta mínima: se vende desde ' ||
                              replace(trim_scale(r.venta_minima)::text, '.', ',') || ' ' ||
                              (SELECT lower(p.unidad_medida) FROM qa.productos p WHERE p.producto_id = s.producto_id) END,
                    nullif(r.alertas, '')), '')                                       AS alertas
        FROM sol s
        LEFT JOIN r ON r.producto_id = s.producto_id)
SELECT * FROM det
UNION ALL
SELECT NULL, NULL, 'TOTAL', NULL, NULL, NULL, NULL,
       sum(valor_estimado), NULL, NULL,
       CASE WHEN bool_and(entrega = 'Inmediata (almacén)') THEN 'Todo disponible para despacho inmediato'
            ELSE 'Hay productos que no salen de inmediato' END,
       NULL
FROM det
ORDER BY 1 NULLS LAST;
$$;
