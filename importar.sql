-- =====================================================================
-- importar.sql  —  lo ejecuta cargar.bat con psql (no correr a mano en el editor de consultas)
-- 1) Vacía las tablas de paso   2) \copy de cada CSV presente en "entrada"
-- 3) CALL qa.cargar_todo()       4) Muestra el resumen y guarda los errores
-- Variables que recibe:  hay_<archivo> = on/off ,  reporte = ruta del CSV de errores
-- =====================================================================
\set ON_ERROR_STOP on
-- facturas_v2 = on si facturas.csv trae las columnas nuevas (lo detecta cargar.bat)
\if :{?facturas_v2}
\else
\set facturas_v2 off
\endif
\pset footer off
\pset pager off

TRUNCATE stg.vendedores, stg.productos, stg.tiempos, stg.precios, stg.clientes, stg.facturas,
         stg.pedidos, stg.inventario, stg.cartera, stg.cotizaciones RESTART IDENTITY;

\if :hay_vendedores
\copy stg.vendedores (codigo, nombre, zona) FROM 'entrada/vendedores.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8')
\endif
\if :hay_productos
\copy stg.productos (referencia, descripcion, tipo, linea, um, venta_minima, estado) FROM 'entrada/productos.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8')
\endif
\if :hay_tiempos_fabricacion
\copy stg.tiempos (referencia, dias) FROM 'entrada/tiempos_fabricacion.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8')
\endif
\if :hay_precios
\copy stg.precios (referencia, nombre, lista_1, lista_2, lista_3, lista_4, venta_minima, comentarios, vigente_desde) FROM 'entrada/precios.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8')
\endif
\if :hay_clientes
\copy stg.clientes (nit, razon_social, ciudad, segmento, estado, lista, vendedor, dias_pago, cupo) FROM 'entrada/clientes.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8')
\endif
\if :hay_facturas
\if :facturas_v2
-- formato oct-2026: + Vendedor, Fecha vencimiento, Factura referencia
\copy stg.facturas (fecha, nit, documento, item_resumen, cantidad, valor_subtotal, lote, pedido, vendedor, fecha_vcto, factura_ref) FROM 'entrada/facturas.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8')
\else
\copy stg.facturas (fecha, nit, documento, item_resumen, cantidad, valor_subtotal, lote, pedido) FROM 'entrada/facturas.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8')
\endif
\endif
\if :hay_pedidos
\copy stg.pedidos (pedido, fecha, nit, vendedor, referencia, cant_pedida, cant_despachada, precio, estado) FROM 'entrada/pedidos.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8')
\endif
\if :hay_inventario
\copy stg.inventario (referencia, descripcion, bodega, lote, ubicacion, presentacion, cantidad, comprometido) FROM 'entrada/inventario.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8')
\endif
\if :hay_cartera
\copy stg.cartera (documento, razon_social, vendedor_nombre, nit, fecha_docto, fecha_vcto, dias_vencidos, total) FROM 'entrada/cartera.csv' WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8')
\endif
\if :hay_cotizaciones
\copy stg.cotizaciones (co, numero, fecha, estado, nit, vendedor, referencia, cantidad, precio, subtotal) FROM 'entrada/cotizaciones.csv' WITH (FORMAT csv, HEADER true, DELIMITER ';', ENCODING 'UTF8')
\endif

CALL qa.cargar_todo(CURRENT_DATE);

\echo
\echo '===== RESUMEN DE LA CARGA ====='
SELECT archivo, filas_cargadas, filas_error FROM qa.v_resumen_ultima_carga;

\echo '===== ERRORES POR MOTIVO ====='
SELECT archivo, nivel, motivo, count(*) AS filas
FROM qa.v_errores_ultima_carga GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;

-- Detalle de errores a un CSV (se abre en Excel)
-- Sugerencias de cambio de NIT (si está instalado qa_10_forecast_base.sql)
SELECT to_regclass('qa.v_posibles_sucesores') IS NOT NULL AS hay_sucesores \gset
\if :hay_sucesores
\echo ''
\echo '===== POSIBLES CAMBIOS DE NIT (revisar: ¿es el mismo negocio?) ====='
SELECT nit_antiguo, nombre_antiguo, nit_nuevo, nombre_nuevo, coincidencia_pct AS "coincidencia %"
FROM qa.v_posibles_sucesores WHERE coincidencia_pct >= 60;
\echo 'Si es el mismo:   CALL qa.pr_enlazar_sucesor(''NIT_ANTIGUO'',''NIT_NUEVO'');'
\echo 'Si no lo es:      CALL qa.pr_descartar_sucesor(''NIT_ANTIGUO'',''NIT_NUEVO'');'
\endif

\o :reporte
COPY (SELECT * FROM qa.v_errores_ultima_carga) TO STDOUT WITH (FORMAT csv, HEADER true);
\o
\echo 'Detalle de errores guardado en:' :reporte
