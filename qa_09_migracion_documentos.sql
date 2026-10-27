/* =====================================================================
   Migración 23/10/2026 — Documentos inmutables e historial de clientes
   ---------------------------------------------------------------------
   ANTES de este archivo, ejecuta la versión nueva de qa_04_carga.sql
   (crea las columnas, la tabla de historial y los procedimientos nuevos).
   Este archivo solo prepara los datos que ya tienes. Se puede ejecutar
   varias veces sin efecto adicional.
   ===================================================================== */
BEGIN;

-- 1) Historial inicial: cada cliente con su lista y vendedor "desde el inicio de los datos"
INSERT INTO qa.clientes_historial (cliente_id, vigente_desde, lista_precio, vendedor_id)
SELECT cliente_id, DATE '2000-01-01', lista_precio, vendedor_id FROM qa.clientes
ON CONFLICT (cliente_id, vigente_desde) DO NOTHING;

-- 2) Cambio conocido: el cliente 844608971 tenía lista 2 hasta el 21/10 y lista 3 desde el 22/10
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM qa.clientes WHERE cliente_id = '844608971' AND lista_precio = 3)
     AND NOT EXISTS (SELECT 1 FROM qa.clientes_historial
                     WHERE cliente_id = '844608971' AND vigente_desde = DATE '2026-10-22') THEN
    UPDATE qa.clientes_historial SET lista_precio = 2
    WHERE cliente_id = '844608971' AND vigente_desde = DATE '2000-01-01';
    INSERT INTO qa.clientes_historial (cliente_id, vigente_desde, lista_precio, vendedor_id)
    SELECT cliente_id, DATE '2026-10-22', 3, vendedor_id FROM qa.clientes WHERE cliente_id = '844608971';
    RAISE NOTICE 'Historial del cliente 844608971: lista 2 hasta 21/10, lista 3 desde 22/10';
  END IF;
END $$;

-- 3) Facturas ya cargadas: su vendedor se dedujo del cliente
UPDATE qa.facturas SET origen_vendedor = 'CLIENTE' WHERE origen_vendedor IS NULL;

-- 4) Notas crédito ya cargadas sin factura de referencia: se deduce la factura que corrigen
--    (mismo cliente, producto y lote, emitida entre 1 y 60 días antes; la más cercana)
UPDATE qa.facturas nc
SET factura_referencia = x.factura
FROM (SELECT DISTINCT ON (n.numero_factura) n.numero_factura AS nc, f.numero_factura AS factura
      FROM qa.facturas n
      JOIN qa.facturas_detalle dn ON dn.numero_factura = n.numero_factura
      JOIN qa.facturas_detalle df ON df.producto_id = dn.producto_id AND df.lote IS NOT DISTINCT FROM dn.lote
      JOIN qa.facturas f ON f.numero_factura = df.numero_factura AND f.tipo = 'FV'
                        AND f.cliente_id = n.cliente_id AND f.fecha BETWEEN n.fecha - 60 AND n.fecha - 1
      WHERE n.tipo = 'NC' AND n.factura_referencia IS NULL
      ORDER BY n.numero_factura, f.fecha DESC) x
WHERE nc.numero_factura = x.nc;

-- 5) Reparación de la carga del 22/10 (la misma de qa_08; no hace nada si ya se aplicó)
UPDATE qa.cotizaciones_detalle d
SET precio_lista_referencia = r.bien, tipo_precio = r.tipo
FROM (VALUES ('CTZ-00005500', 1,  77600.00,  81900.00, 'UNICA_VEZ'),
             ('CTZ-00005500', 2,  46700.00,  49300.00, 'UNICA_VEZ'),
             ('CTZ-00005584', 1, 192800.00, 203500.00, 'UNICA_VEZ')) AS r(doc, linea, mal, bien, tipo)
WHERE d.numero_cotizacion = r.doc AND d.linea = r.linea AND d.precio_lista_referencia = r.mal;

COMMIT;

SELECT (SELECT count(*) FROM qa.clientes_historial)                                   AS filas_historial,
       (SELECT count(*) FROM qa.facturas WHERE tipo = 'NC')                           AS notas_credito,
       (SELECT count(*) FROM qa.facturas WHERE tipo = 'NC' AND factura_referencia IS NOT NULL) AS nc_enlazadas;
