/* =====================================================================
   BASE COMERCIAL — Script 04: KIT DE CARGA (CSV del ERP → esquema qa)
   Requiere qa_01_esquema.sql. Se puede ejecutar varias veces.
   ---------------------------------------------------------------------
   Flujo:  CSV en carpeta "entrada"
             → \copy a tablas de paso (esquema stg, todo como texto)
             → CALL qa.cargar_todo()  limpia, valida y carga al esquema qa
             → filas con problemas quedan en qa.carga_errores
   Toda la corrida es una sola transacción: o carga todo o no carga nada.
   ===================================================================== */

CREATE SCHEMA IF NOT EXISTS stg;

/* ---------------------------------------------------------------------
   1. Funciones de limpieza
   --------------------------------------------------------------------- */

-- Números estilo es-CO:   "$1.062.000,00"  "0,25"  → punto = miles, coma = decimal
CREATE OR REPLACE FUNCTION stg.num_co(t TEXT) RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN replace(replace(regexp_replace(btrim(t), '[$\s]', '', 'g'), '.', ''), ',', '.')::numeric;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

-- Números estilo inglés: "2,135,455"  "236.00" → coma = miles, punto = decimal
CREATE OR REPLACE FUNCTION stg.num_us(t TEXT) RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN replace(regexp_replace(btrim(t), '[$\s]', '', 'g'), ',', '')::numeric;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

-- Fechas con formato explícito; NULL si viene vacía o inválida
CREATE OR REPLACE FUNCTION stg.fecha(t TEXT, formato TEXT) RETURNS DATE
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE d DATE;
BEGIN
  IF nullif(btrim(t), '') IS NULL THEN RETURN NULL; END IF;
  d := to_date(btrim(t), formato);
  IF to_char(d, formato) <> btrim(t)                     -- evita que 13/25/2026 "pase"
     AND to_char(d, replace(replace(formato, 'MM', 'FMMM'), 'DD', 'FMDD')) <> btrim(t) THEN
     RETURN NULL;
  END IF;
  RETURN d;
EXCEPTION WHEN others THEN RETURN NULL;
END $$;

-- NIT / cédula: solo dígitos  ("901,802,759" → "901802759")
CREATE OR REPLACE FUNCTION stg.nit(t TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$ SELECT nullif(regexp_replace(coalesce(t, ''), '[^0-9]', '', 'g'), '') $$;

-- Texto vacío → NULL
CREATE OR REPLACE FUNCTION stg.txt(t TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$ SELECT nullif(btrim(t), '') $$;

/* ---------------------------------------------------------------------
   2. Tablas de paso (una por archivo, columnas en el orden del CSV)
   --------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS stg.vendedores   (fila BIGSERIAL, codigo TEXT, nombre TEXT, zona TEXT);
CREATE TABLE IF NOT EXISTS stg.productos    (fila BIGSERIAL, referencia TEXT, descripcion TEXT, tipo TEXT,
                                             linea TEXT, um TEXT, venta_minima TEXT, estado TEXT);
CREATE TABLE IF NOT EXISTS stg.tiempos      (fila BIGSERIAL, referencia TEXT, dias TEXT);
CREATE TABLE IF NOT EXISTS stg.precios      (fila BIGSERIAL, referencia TEXT, nombre TEXT, lista_1 TEXT,
                                             lista_2 TEXT, lista_3 TEXT, lista_4 TEXT, venta_minima TEXT,
                                             comentarios TEXT, vigente_desde TEXT);
CREATE TABLE IF NOT EXISTS stg.clientes     (fila BIGSERIAL, nit TEXT, razon_social TEXT, ciudad TEXT,
                                             segmento TEXT, estado TEXT, lista TEXT, vendedor TEXT,
                                             dias_pago TEXT, cupo TEXT);
CREATE TABLE IF NOT EXISTS stg.facturas     (fila BIGSERIAL, fecha TEXT, nit TEXT, documento TEXT,
                                             item_resumen TEXT, cantidad TEXT, valor_subtotal TEXT,
                                             lote TEXT, pedido TEXT);
-- Columnas nuevas (formato oct-2026). Son opcionales: si el archivo no las trae quedan vacías.
ALTER TABLE stg.facturas ADD COLUMN IF NOT EXISTS vendedor    TEXT;
ALTER TABLE stg.facturas ADD COLUMN IF NOT EXISTS fecha_vcto  TEXT;
ALTER TABLE stg.facturas ADD COLUMN IF NOT EXISTS factura_ref TEXT;
CREATE TABLE IF NOT EXISTS stg.pedidos      (fila BIGSERIAL, pedido TEXT, fecha TEXT, nit TEXT, vendedor TEXT,
                                             referencia TEXT, cant_pedida TEXT, cant_despachada TEXT,
                                             precio TEXT, estado TEXT);
CREATE TABLE IF NOT EXISTS stg.inventario   (fila BIGSERIAL, referencia TEXT, descripcion TEXT, bodega TEXT,
                                             lote TEXT, ubicacion TEXT, presentacion TEXT, cantidad TEXT,
                                             comprometido TEXT);
CREATE TABLE IF NOT EXISTS stg.cartera      (fila BIGSERIAL, documento TEXT, razon_social TEXT,
                                             vendedor_nombre TEXT, nit TEXT, fecha_docto TEXT,
                                             fecha_vcto TEXT, dias_vencidos TEXT, total TEXT);
CREATE TABLE IF NOT EXISTS stg.cotizaciones (fila BIGSERIAL, co TEXT, numero TEXT, fecha TEXT, estado TEXT,
                                             nit TEXT, vendedor TEXT, referencia TEXT, cantidad TEXT,
                                             precio TEXT, subtotal TEXT);

/* ---------------------------------------------------------------------
   2b. Ampliaciones del esquema qa (oct-2026)
       - Facturas inmutables: vendedor del documento y nota crédito enlazada
       - Historial de lista de precios y vendedor de cada cliente
       - Cliente sucesor (cuando una empresa cambia de NIT)
   --------------------------------------------------------------------- */
ALTER TABLE qa.facturas ADD COLUMN IF NOT EXISTS factura_referencia VARCHAR(30);   -- NC → factura que corrige
ALTER TABLE qa.facturas ADD COLUMN IF NOT EXISTS origen_vendedor    VARCHAR(10);   -- FACTURA / PEDIDO / CLIENTE
ALTER TABLE qa.clientes ADD COLUMN IF NOT EXISTS cliente_sucesor    VARCHAR(20) REFERENCES qa.clientes(cliente_id);

CREATE TABLE IF NOT EXISTS qa.clientes_historial (
    cliente_id    VARCHAR(20) NOT NULL REFERENCES qa.clientes(cliente_id),
    vigente_desde DATE        NOT NULL,
    lista_precio  SMALLINT,
    vendedor_id   VARCHAR(20) REFERENCES qa.vendedores(vendedor_id),
    PRIMARY KEY (cliente_id, vigente_desde)
);
COMMENT ON TABLE qa.clientes_historial IS
  'Una fila cada vez que cambia la lista de precios o el vendedor de un cliente. 2000-01-01 = desde el inicio de los datos.';

-- Lista de precios / vendedor que tenía un cliente en una fecha
CREATE OR REPLACE FUNCTION qa.fn_lista_cliente(p_cliente VARCHAR, p_fecha DATE) RETURNS SMALLINT
LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    (SELECT h.lista_precio FROM qa.clientes_historial h
     WHERE h.cliente_id = p_cliente AND h.vigente_desde <= p_fecha ORDER BY h.vigente_desde DESC LIMIT 1),
    (SELECT h.lista_precio FROM qa.clientes_historial h
     WHERE h.cliente_id = p_cliente ORDER BY h.vigente_desde LIMIT 1),
    (SELECT c.lista_precio FROM qa.clientes c WHERE c.cliente_id = p_cliente));
$$;
CREATE OR REPLACE FUNCTION qa.fn_vendedor_cliente(p_cliente VARCHAR, p_fecha DATE) RETURNS VARCHAR
LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    (SELECT h.vendedor_id FROM qa.clientes_historial h
     WHERE h.cliente_id = p_cliente AND h.vigente_desde <= p_fecha ORDER BY h.vigente_desde DESC LIMIT 1),
    (SELECT h.vendedor_id FROM qa.clientes_historial h
     WHERE h.cliente_id = p_cliente ORDER BY h.vigente_desde LIMIT 1),
    (SELECT c.vendedor_id FROM qa.clientes c WHERE c.cliente_id = p_cliente));
$$;

/* ---------------------------------------------------------------------
   3. Registro de corridas y errores
   --------------------------------------------------------------------- */
CREATE SEQUENCE IF NOT EXISTS qa.seq_corrida;
ALTER TABLE qa.log_cargas ADD COLUMN IF NOT EXISTS corrida INTEGER;
ALTER TABLE qa.log_cargas ADD COLUMN IF NOT EXISTS filas_error INTEGER;

CREATE TABLE IF NOT EXISTS qa.carga_errores (
    id        BIGSERIAL PRIMARY KEY,
    corrida   INTEGER     NOT NULL,
    archivo   VARCHAR(60) NOT NULL,
    linea     BIGINT,                       -- línea del archivo (1 = encabezado)
    nivel     VARCHAR(12) NOT NULL DEFAULT 'ERROR'
              CHECK (nivel IN ('ERROR','ADVERTENCIA')),   -- ERROR = fila no cargada
    motivo    TEXT        NOT NULL,
    datos     TEXT,
    creado_en TIMESTAMP   NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_carga_err_corrida ON qa.carga_errores (corrida);

CREATE OR REPLACE PROCEDURE qa.registrar_carga(p_corrida INT, p_archivo TEXT, p_tabla TEXT, p_ok INT)
LANGUAGE plpgsql AS $$
DECLARE n_err INT;
BEGIN
  SELECT count(*) INTO n_err FROM qa.carga_errores
  WHERE corrida = p_corrida AND archivo = p_archivo AND nivel = 'ERROR';
  INSERT INTO qa.log_cargas (tabla_destino, archivo, filas, filas_error, corrida, observaciones)
  VALUES (p_tabla, p_archivo, p_ok, n_err, p_corrida,
          p_ok || ' filas cargadas, ' || n_err || ' con error');
END $$;

-- Pasa las filas marcadas con motivo de _v a qa.carga_errores
CREATE OR REPLACE PROCEDURE qa.guardar_errores(p_corrida INT, p_archivo TEXT)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO qa.carga_errores (corrida, archivo, linea, nivel, motivo, datos)
  SELECT p_corrida, p_archivo, fila + 1, 'ERROR', motivo, datos FROM _v WHERE motivo IS NOT NULL;
END $$;

/* =====================================================================
   4. Un procedimiento por archivo
   Patrón: _v = filas limpias + columna "motivo" (NULL = fila válida)
   ===================================================================== */

-- 4.1 Vendedores --------------------------------------------------------
CREATE OR REPLACE PROCEDURE qa.cargar_vendedores(p_corrida INT)
LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM stg.vendedores) THEN RETURN; END IF;
  DROP TABLE IF EXISTS _v;
  CREATE TEMP TABLE _v AS
  SELECT s.fila, row_to_json(s)::text AS datos,
         upper(stg.txt(s.codigo)) AS vendedor_id, stg.txt(s.nombre) AS nombre, stg.txt(s.zona) AS zona,
         CASE WHEN stg.txt(s.codigo) IS NULL THEN 'Código de vendedor vacío'
              WHEN stg.txt(s.nombre) IS NULL THEN 'Nombre vacío' END AS motivo
  FROM stg.vendedores s;
  CALL qa.guardar_errores(p_corrida, 'vendedores.csv');

  INSERT INTO qa.vendedores (vendedor_id, nombre, zona)
  SELECT DISTINCT ON (vendedor_id) vendedor_id, nombre, zona FROM _v WHERE motivo IS NULL ORDER BY vendedor_id, fila
  ON CONFLICT (vendedor_id) DO UPDATE SET nombre = EXCLUDED.nombre, zona = EXCLUDED.zona;
  GET DIAGNOSTICS n = ROW_COUNT;
  CALL qa.registrar_carga(p_corrida, 'vendedores.csv', 'vendedores', n);
END $$;

-- 4.2 Productos ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE qa.cargar_productos(p_corrida INT)
LANGUAGE plpgsql AS $$
DECLARE n1 INT; n2 INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM stg.productos) THEN RETURN; END IF;
  DROP TABLE IF EXISTS _v;
  CREATE TEMP TABLE _v AS
  WITH b AS (
    SELECT s.fila, row_to_json(s)::text AS datos,
           qa.fn_codigo(stg.txt(s.referencia))                 AS producto_id,
           stg.txt(s.descripcion)                              AS nombre,
           CASE upper(stg.txt(s.tipo))
                WHEN 'PRODUCTO FABRICADO' THEN 'FABRICADO' WHEN 'FABRICADO' THEN 'FABRICADO'
                WHEN 'COMERCIALIZADO' THEN 'DISTRIBUIDO'  WHEN 'DISTRIBUIDO' THEN 'DISTRIBUIDO'
                ELSE 'SIN_TIPO' END                            AS tipo,
           stg.txt(s.linea)                                    AS categoria,
           substring(upper(stg.txt(s.linea)) FROM '^L[IÍ]NEA\s+([A-Z0-9]{1,5})$') AS familia,   -- "Línea A" → A
           coalesce(upper(stg.txt(s.um)), 'KG')                AS unidad,
           stg.num_co(s.venta_minima)                          AS venta_minima,
           CASE WHEN upper(stg.txt(s.estado)) IN ('DESCONTINUADO','INACTIVO') THEN 'DESCONTINUADO'
                ELSE 'ACTIVO' END                              AS estado
    FROM stg.productos s)
  SELECT b.*,
         CASE WHEN b.producto_id ~ '^\d+E$' THEN qa.fn_codigo(regexp_replace(b.producto_id, 'E$', '')) END AS base,
         CASE WHEN b.producto_id IS NULL THEN 'Referencia vacía'
              WHEN b.nombre IS NULL      THEN 'Descripción vacía'
              WHEN row_number() OVER (PARTITION BY b.producto_id ORDER BY b.fila) > 1
                                         THEN 'Referencia repetida en el archivo' END AS motivo
  FROM b;
  CALL qa.guardar_errores(p_corrida, 'productos.csv');

  -- primero los productos base, luego las variantes "E" (dependen de su base)
  INSERT INTO qa.productos (producto_id, nombre, categoria, familia, tipo, unidad_medida, venta_minima, estado)
  SELECT producto_id, nombre, categoria, familia, tipo, unidad, venta_minima, estado
  FROM _v WHERE motivo IS NULL AND base IS NULL
  ON CONFLICT (producto_id) DO UPDATE SET
     nombre = EXCLUDED.nombre, categoria = EXCLUDED.categoria, familia = coalesce(EXCLUDED.familia, qa.productos.familia),
     tipo = EXCLUDED.tipo, unidad_medida = EXCLUDED.unidad_medida,
     venta_minima = EXCLUDED.venta_minima, estado = EXCLUDED.estado, actualizado_en = now();
  GET DIAGNOSTICS n1 = ROW_COUNT;

  INSERT INTO qa.productos (producto_id, nombre, categoria, familia, tipo, producto_base, unidad_medida, venta_minima, estado)
  SELECT v.producto_id, v.nombre, v.categoria, v.familia, v.tipo,
         CASE WHEN EXISTS (SELECT 1 FROM qa.productos p WHERE p.producto_id = v.base) THEN v.base END,
         v.unidad, v.venta_minima, v.estado
  FROM _v v WHERE v.motivo IS NULL AND v.base IS NOT NULL
  ON CONFLICT (producto_id) DO UPDATE SET
     nombre = EXCLUDED.nombre, categoria = EXCLUDED.categoria, familia = coalesce(EXCLUDED.familia, qa.productos.familia),
     tipo = EXCLUDED.tipo, producto_base = EXCLUDED.producto_base, unidad_medida = EXCLUDED.unidad_medida,
     venta_minima = EXCLUDED.venta_minima, estado = EXCLUDED.estado, actualizado_en = now();
  GET DIAGNOSTICS n2 = ROW_COUNT;
  CALL qa.registrar_carga(p_corrida, 'productos.csv', 'productos', n1 + n2);
END $$;

-- 4.3 Tiempos de fabricación (archivo de Producción) -------------------
CREATE OR REPLACE PROCEDURE qa.cargar_tiempos(p_corrida INT)
LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM stg.tiempos) THEN RETURN; END IF;
  DROP TABLE IF EXISTS _v;
  CREATE TEMP TABLE _v AS
  SELECT s.fila, row_to_json(s)::text AS datos, qa.fn_codigo(stg.txt(s.referencia)) AS producto_id,
         stg.num_co(s.dias)::int AS dias,
         CASE WHEN NOT EXISTS (SELECT 1 FROM qa.productos p WHERE p.producto_id = qa.fn_codigo(stg.txt(s.referencia)))
                   THEN 'Producto no existe'
              WHEN stg.num_co(s.dias) IS NULL OR stg.num_co(s.dias) < 0 THEN 'Días inválidos' END AS motivo
  FROM stg.tiempos s;
  CALL qa.guardar_errores(p_corrida, 'tiempos_fabricacion.csv');

  UPDATE qa.productos p SET tiempo_fabricacion_dias = v.dias
  FROM _v v WHERE v.motivo IS NULL AND v.producto_id = p.producto_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  CALL qa.registrar_carga(p_corrida, 'tiempos_fabricacion.csv', 'productos', n);
END $$;

-- 4.4 Precios (historial: solo se agrega una fila si el precio cambió) --
CREATE OR REPLACE PROCEDURE qa.cargar_precios(p_corrida INT, p_fecha DATE)
LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM stg.precios) THEN RETURN; END IF;
  DROP TABLE IF EXISTS _v;
  CREATE TEMP TABLE _v AS
  WITH b AS (
    SELECT s.fila, row_to_json(s)::text AS datos,
           qa.fn_codigo(stg.txt(s.referencia)) AS producto_id,
           coalesce(stg.fecha(s.vigente_desde, 'DD/MM/YYYY'), p_fecha) AS vigente_desde,
           stg.num_us(s.lista_1) l1, stg.num_us(s.lista_2) l2, stg.num_us(s.lista_3) l3, stg.num_us(s.lista_4) l4,
           stg.txt(s.comentarios) AS comentarios
    FROM stg.precios s)
  SELECT b.*,
         CASE WHEN NOT EXISTS (SELECT 1 FROM qa.productos p WHERE p.producto_id = b.producto_id) THEN 'Producto no existe'
              WHEN b.l1 IS NULL OR b.l1 <= 0 THEN 'Precio de lista 01 inválido'
              WHEN row_number() OVER (PARTITION BY b.producto_id, b.vigente_desde ORDER BY b.fila) > 1
                   THEN 'Precio repetido para la misma fecha' END AS motivo
  FROM b;
  CALL qa.guardar_errores(p_corrida, 'precios.csv');

  INSERT INTO qa.precios (producto_id, vigente_desde, lista_1, lista_2, lista_3, lista_4)
  SELECT v.producto_id, v.vigente_desde, v.l1, v.l2, v.l3, v.l4
  FROM _v v
  WHERE v.motivo IS NULL
    AND NOT EXISTS (            -- no repetir si es igual al precio vigente anterior
        SELECT 1 FROM (SELECT * FROM qa.precios q WHERE q.producto_id = v.producto_id
                         AND q.vigente_desde < v.vigente_desde ORDER BY q.vigente_desde DESC LIMIT 1) ant
        WHERE (ant.lista_1, ant.lista_2, ant.lista_3, ant.lista_4) IS NOT DISTINCT FROM (v.l1, v.l2, v.l3, v.l4))
  ON CONFLICT (producto_id, vigente_desde) DO UPDATE SET
     lista_1 = EXCLUDED.lista_1, lista_2 = EXCLUDED.lista_2, lista_3 = EXCLUDED.lista_3, lista_4 = EXCLUDED.lista_4;
  GET DIAGNOSTICS n = ROW_COUNT;

  -- el comentario más reciente queda en el producto
  UPDATE qa.productos p SET comentarios = c.comentarios
  FROM (SELECT DISTINCT ON (producto_id) producto_id, comentarios FROM _v
        WHERE motivo IS NULL ORDER BY producto_id, vigente_desde DESC) c
  WHERE c.producto_id = p.producto_id AND p.comentarios IS DISTINCT FROM c.comentarios;
  CALL qa.registrar_carga(p_corrida, 'precios.csv', 'precios', n);
END $$;

-- 4.5 Clientes ----------------------------------------------------------
DROP PROCEDURE IF EXISTS qa.cargar_clientes(INT);
CREATE OR REPLACE PROCEDURE qa.cargar_clientes(p_corrida INT, p_fecha DATE)
LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM stg.clientes) THEN RETURN; END IF;
  DROP TABLE IF EXISTS _v;
  CREATE TEMP TABLE _v AS
  WITH b AS (
    SELECT s.fila, row_to_json(s)::text AS datos,
           stg.nit(s.nit) AS cliente_id, stg.txt(s.razon_social) AS nombre, stg.txt(s.ciudad) AS ciudad,
           CASE WHEN upper(s.segmento) IN ('EMPRESA','EMPRENDEDOR') THEN upper(s.segmento) END AS segmento,
           CASE WHEN upper(s.estado) IN ('ACTIVO','INACTIVO','BLOQUEADO') THEN upper(s.estado) ELSE 'ACTIVO' END AS estado,
           stg.num_co(s.lista)::int AS lista,
           upper(stg.txt(s.vendedor)) AS vendedor_id,
           stg.num_co(s.dias_pago)::int AS dias_pago,
           stg.num_us(s.cupo) AS cupo
    FROM stg.clientes s)
  SELECT b.*,
         CASE WHEN b.cliente_id IS NULL THEN 'NIT vacío'
              WHEN b.nombre IS NULL     THEN 'Razón social vacía'
              WHEN b.lista NOT BETWEEN 1 AND 4 OR b.lista IS NULL THEN 'Lista de precios inválida (debe ser 1 a 4)'
              WHEN row_number() OVER (PARTITION BY b.cliente_id ORDER BY b.fila) > 1 THEN 'NIT repetido en el archivo' END AS motivo
  FROM b;
  CALL qa.guardar_errores(p_corrida, 'clientes.csv');

  INSERT INTO qa.carga_errores (corrida, archivo, linea, nivel, motivo, datos)
  SELECT p_corrida, 'clientes.csv', fila + 1, 'ADVERTENCIA', 'Vendedor no existe: se carga sin vendedor', datos
  FROM _v WHERE motivo IS NULL AND vendedor_id IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM qa.vendedores x WHERE x.vendedor_id = _v.vendedor_id);

  INSERT INTO qa.clientes (cliente_id, nombre, estado, ciudad, segmento, lista_precio, vendedor_id,
                           condicion_pago_dias, cupo_credito)
  SELECT v.cliente_id, v.nombre, v.estado, v.ciudad, v.segmento, v.lista,
         (SELECT x.vendedor_id FROM qa.vendedores x WHERE x.vendedor_id = v.vendedor_id),
         v.dias_pago, v.cupo
  FROM _v v WHERE v.motivo IS NULL
  ON CONFLICT (cliente_id) DO UPDATE SET
     nombre = EXCLUDED.nombre, ciudad = EXCLUDED.ciudad, segmento = EXCLUDED.segmento,
     -- un NIT enlazado a su sucesor queda INACTIVO aunque el ERP lo siga mostrando activo
     estado = CASE WHEN qa.clientes.cliente_sucesor IS NOT NULL THEN 'INACTIVO' ELSE EXCLUDED.estado END,
     lista_precio = EXCLUDED.lista_precio, vendedor_id = EXCLUDED.vendedor_id,
     condicion_pago_dias = EXCLUDED.condicion_pago_dias, cupo_credito = EXCLUDED.cupo_credito, actualizado_en = now();
  GET DIAGNOSTICS n = ROW_COUNT;

  -- Historial: nueva fila solo si cambió la lista o el vendedor (recargar el mismo día la reemplaza)
  INSERT INTO qa.clientes_historial (cliente_id, vigente_desde, lista_precio, vendedor_id)
  SELECT c.cliente_id,
         CASE WHEN EXISTS (SELECT 1 FROM qa.clientes_historial x WHERE x.cliente_id = c.cliente_id)
              THEN p_fecha ELSE DATE '2000-01-01' END,            -- primera vez: "desde el inicio"
         c.lista_precio, c.vendedor_id
  FROM qa.clientes c
  LEFT JOIN LATERAL (SELECT h.lista_precio, h.vendedor_id FROM qa.clientes_historial h
                     WHERE h.cliente_id = c.cliente_id AND h.vigente_desde < p_fecha
                     ORDER BY h.vigente_desde DESC LIMIT 1) u ON TRUE
  WHERE c.cliente_id IN (SELECT cliente_id FROM _v WHERE motivo IS NULL)
    AND (u.lista_precio IS DISTINCT FROM c.lista_precio OR u.vendedor_id IS DISTINCT FROM c.vendedor_id)
  ON CONFLICT (cliente_id, vigente_desde) DO UPDATE
     SET lista_precio = EXCLUDED.lista_precio, vendedor_id = EXCLUDED.vendedor_id;
  -- si hoy volvió a quedar igual que antes, la fila de hoy sobra
  DELETE FROM qa.clientes_historial h
  WHERE h.vigente_desde = p_fecha AND h.cliente_id IN (SELECT cliente_id FROM _v WHERE motivo IS NULL)
    AND EXISTS (SELECT 1 FROM (SELECT u.lista_precio, u.vendedor_id FROM qa.clientes_historial u
                               WHERE u.cliente_id = h.cliente_id AND u.vigente_desde < h.vigente_desde
                               ORDER BY u.vigente_desde DESC LIMIT 1) u
                WHERE u.lista_precio IS NOT DISTINCT FROM h.lista_precio
                  AND u.vendedor_id  IS NOT DISTINCT FROM h.vendedor_id);

  CALL qa.registrar_carga(p_corrida, 'clientes.csv', 'clientes', n);
END $$;

-- Precio de lista de referencia de un cliente para un producto en una fecha
CREATE OR REPLACE FUNCTION qa.fn_precio_lista(p_cliente VARCHAR, p_producto VARCHAR, p_fecha DATE)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
  SELECT CASE qa.fn_lista_cliente(c.cliente_id, p_fecha)
              WHEN 1 THEN pr.lista_1 WHEN 2 THEN pr.lista_2
              WHEN 3 THEN pr.lista_3 WHEN 4 THEN pr.lista_4 END
  FROM qa.clientes c
  JOIN LATERAL (SELECT * FROM qa.precios q WHERE q.producto_id = p_producto AND q.vigente_desde <= p_fecha
                ORDER BY q.vigente_desde DESC LIMIT 1) pr ON TRUE
  WHERE c.cliente_id = p_cliente;
$$;

-- Clasifica el precio cobrado: ESPECIAL / LISTA / UNICA_VEZ (tolerancia 1 %)
CREATE OR REPLACE FUNCTION qa.fn_tipo_precio(p_cliente VARCHAR, p_producto VARCHAR, p_fecha DATE,
                                             p_precio NUMERIC, p_lista NUMERIC)
RETURNS VARCHAR LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN EXISTS (SELECT 1 FROM qa.precios_especiales e
                 WHERE e.cliente_id = p_cliente AND e.producto_id = p_producto
                   AND e.vigente_desde <= p_fecha AND (e.vigente_hasta IS NULL OR e.vigente_hasta >= p_fecha)
                   AND abs(p_precio / nullif(e.precio_especial, 0) - 1) <= 0.01) THEN 'ESPECIAL'
    WHEN p_lista > 0 AND abs(p_precio / p_lista - 1) <= 0.01 THEN 'LISTA'
    ELSE 'UNICA_VEZ' END;
$$;

-- 4.6 Facturas y notas crédito (una fila por línea) ---------------------
-- Las facturas son INMUTABLES: una vez cargada, no se modifica. Las correcciones
-- llegan como notas crédito (NC), que son documentos nuevos.
--   · Documento nuevo  → se inserta completo.
--   · Documento ya cargado → se ignora (si llega distinto, queda una ADVERTENCIA).
--   · Si una línea tiene error, se rechaza la factura COMPLETA (nunca a medias);
--     entra entera el día que se corrija el problema.
--   · Vendedor: el de la factura; si no viene, el de su pedido; si no, el que tenía
--     el cliente en la fecha de la factura (historial).
CREATE OR REPLACE PROCEDURE qa.cargar_facturas(p_corrida INT)
LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM stg.facturas) THEN RETURN; END IF;
  DROP TABLE IF EXISTS _v;
  CREATE TEMP TABLE _v AS
  WITH b AS (
    SELECT s.fila, row_to_json(s)::text AS datos,
           stg.fecha(s.fecha, 'MM/DD/YYYY')                        AS fecha,
           stg.nit(s.nit)                                          AS cliente_id,
           upper(stg.txt(s.documento))                             AS numero_factura,
           qa.fn_codigo(split_part(btrim(s.item_resumen), ' ', 1)) AS producto_id,
           stg.num_us(s.cantidad)                                  AS cantidad,
           stg.num_us(s.valor_subtotal)                            AS valor,
           stg.txt(s.lote)                                         AS lote,
           upper(stg.txt(s.pedido))                                AS numero_pedido,
           upper(stg.txt(s.vendedor))                              AS vendedor_doc,
           stg.fecha(s.fecha_vcto, 'MM/DD/YYYY')                   AS fecha_vcto,
           upper(stg.txt(s.factura_ref))                           AS factura_ref
    FROM stg.facturas s),
  m AS (
    SELECT b.*,
           CASE WHEN b.numero_factura IS NULL THEN 'Número de documento vacío'
                WHEN b.fecha IS NULL         THEN 'Fecha vacía o inválida'
                WHEN NOT EXISTS (SELECT 1 FROM qa.clientes c WHERE c.cliente_id = b.cliente_id) THEN 'Cliente no existe'
                WHEN NOT EXISTS (SELECT 1 FROM qa.productos p WHERE p.producto_id = b.producto_id) THEN 'Producto no existe'
                WHEN b.cantidad IS NULL OR b.cantidad = 0 THEN 'Cantidad vacía o cero'
                WHEN b.valor IS NULL THEN 'Valor inválido' END AS motivo_linea
    FROM b)
  SELECT m.*,
         coalesce(m.motivo_linea,
                  CASE WHEN m.numero_factura IS NOT NULL
                        AND bool_or(m.motivo_linea IS NOT NULL) OVER (PARTITION BY m.numero_factura)
                       THEN 'Otra línea de esta factura tiene error: se rechaza completa' END) AS motivo,
         EXISTS (SELECT 1 FROM qa.facturas f WHERE f.numero_factura = m.numero_factura) AS ya_existe
  FROM m;
  CALL qa.guardar_errores(p_corrida, 'facturas.csv');

  -- Documentos ya cargados que llegan con datos distintos: no se tocan, se avisa
  INSERT INTO qa.carga_errores (corrida, archivo, linea, nivel, motivo, datos)
  SELECT p_corrida, 'facturas.csv', min(v.fila) + 1, 'ADVERTENCIA',
         'Factura ya cargada con datos distintos: se conserva la original (las correcciones van por nota crédito)',
         json_build_object('documento', v.numero_factura, 'lineas_archivo', count(*),
                           'valor_archivo', sum(v.valor), 'valor_base', max(x.valor), 'lineas_base', max(x.lineas))::text
  FROM _v v
  JOIN (SELECT numero_factura, count(*) AS lineas, sum(valor_subtotal) AS valor
        FROM qa.facturas_detalle GROUP BY 1) x USING (numero_factura)
  WHERE v.motivo IS NULL AND v.ya_existe
  GROUP BY v.numero_factura
  HAVING count(*) <> max(x.lineas) OR abs(sum(v.valor) - max(x.valor)) > 1;

  -- Avisos de los documentos nuevos
  INSERT INTO qa.carga_errores (corrida, archivo, linea, nivel, motivo, datos)
  SELECT p_corrida, 'facturas.csv', fila + 1, 'ADVERTENCIA', aviso, datos
  FROM (SELECT DISTINCT ON (numero_factura) fila, datos,
               CASE WHEN vendedor_doc IS NOT NULL
                     AND NOT EXISTS (SELECT 1 FROM qa.vendedores x WHERE x.vendedor_id = v.vendedor_doc)
                      THEN 'Vendedor de la factura no existe: se toma el del pedido o el del cliente'
                    WHEN numero_factura LIKE 'NC%' AND factura_ref IS NULL
                      THEN 'Nota crédito sin factura de referencia'
                    WHEN numero_factura LIKE 'NC%'
                     AND NOT EXISTS (SELECT 1 FROM qa.facturas f WHERE f.numero_factura = v.factura_ref)
                     AND NOT EXISTS (SELECT 1 FROM _v w WHERE w.numero_factura = v.factura_ref AND w.motivo IS NULL)
                      THEN 'Nota crédito referencia una factura que no está en la base' END AS aviso
        FROM _v v WHERE motivo IS NULL AND NOT ya_existe ORDER BY numero_factura, fila) a
  WHERE aviso IS NOT NULL;

  -- Encabezados de los documentos nuevos
  INSERT INTO qa.facturas (numero_factura, cliente_id, vendedor_id, origen_vendedor, numero_pedido, fecha,
                           fecha_vencimiento, tipo, factura_referencia)
  SELECT h.numero_factura, h.cliente_id,
         coalesce(vf.vendedor_id, p.vendedor_id, qa.fn_vendedor_cliente(h.cliente_id, h.fecha)),
         CASE WHEN vf.vendedor_id IS NOT NULL THEN 'FACTURA'
              WHEN p.vendedor_id  IS NOT NULL THEN 'PEDIDO' ELSE 'CLIENTE' END,
         h.numero_pedido, h.fecha,
         coalesce(h.fecha_vcto, h.fecha + coalesce(c.condicion_pago_dias, 0)),
         CASE WHEN h.numero_factura LIKE 'NC%' THEN 'NC' ELSE 'FV' END,
         h.factura_ref
  FROM (SELECT DISTINCT ON (numero_factura) numero_factura, cliente_id, fecha, numero_pedido,
               vendedor_doc, fecha_vcto, factura_ref
        FROM _v WHERE motivo IS NULL AND NOT ya_existe ORDER BY numero_factura, fila) h
  JOIN qa.clientes c USING (cliente_id)
  LEFT JOIN qa.vendedores vf ON vf.vendedor_id = h.vendedor_doc
  LEFT JOIN qa.pedidos p ON p.numero_pedido = h.numero_pedido;

  -- Detalle de los documentos nuevos (precio clasificado con la lista que tenía el cliente ese día)
  INSERT INTO qa.facturas_detalle (numero_factura, linea, producto_id, lote, cantidad, valor_subtotal,
                                   precio_lista_referencia, tipo_precio)
  SELECT x.numero_factura, x.linea, x.producto_id, x.lote, x.cantidad, x.valor, x.ref,
         qa.fn_tipo_precio(x.cliente_id, x.producto_id, x.fecha, x.valor / x.cantidad, x.ref)
  FROM (SELECT v.*, row_number() OVER (PARTITION BY v.numero_factura ORDER BY v.fila) AS linea,
               qa.fn_precio_lista(v.cliente_id, v.producto_id, v.fecha) AS ref
        FROM _v v WHERE v.motivo IS NULL AND NOT v.ya_existe) x;
  GET DIAGNOSTICS n = ROW_COUNT;

  -- Fecha de lanzamiento = primera venta (si nadie la ha definido)
  UPDATE qa.productos p SET fecha_lanzamiento = f.primera
  FROM (SELECT d.producto_id, min(f.fecha) AS primera
        FROM qa.facturas_detalle d JOIN qa.facturas f USING (numero_factura) GROUP BY 1) f
  WHERE f.producto_id = p.producto_id AND p.fecha_lanzamiento IS NULL;

  CALL qa.registrar_carga(p_corrida, 'facturas.csv', 'facturas (líneas nuevas)', n);
END $$;

-- 4.7 Pedidos (una fila por línea de pedido) -----------------------------
CREATE OR REPLACE PROCEDURE qa.cargar_pedidos(p_corrida INT)
LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM stg.pedidos) THEN RETURN; END IF;
  DROP TABLE IF EXISTS _v;
  CREATE TEMP TABLE _v AS
  WITH b AS (
    SELECT s.fila, row_to_json(s)::text AS datos,
           upper(stg.txt(s.pedido)) AS numero_pedido, stg.fecha(s.fecha, 'DD/MM/YYYY') AS fecha,
           stg.nit(s.nit) AS cliente_id, upper(stg.txt(s.vendedor)) AS vendedor_id,
           qa.fn_codigo(stg.txt(s.referencia)) AS producto_id,
           stg.num_us(s.cant_pedida) AS cant_pedida, coalesce(stg.num_us(s.cant_despachada), 0) AS cant_desp,
           stg.num_us(s.precio) AS precio,
           CASE upper(stg.txt(s.estado)) WHEN 'ABIERTO' THEN 'ABIERTO' WHEN 'PARCIAL' THEN 'PARCIAL'
                WHEN 'CERRADO' THEN 'CERRADO' WHEN 'ANULADO' THEN 'ANULADO' END AS estado
    FROM stg.pedidos s)
  SELECT b.*,
         CASE WHEN b.numero_pedido IS NULL THEN 'Número de pedido vacío'
              WHEN b.fecha IS NULL THEN 'Fecha vacía o inválida'
              WHEN b.estado IS NULL THEN 'Estado inválido'
              WHEN NOT EXISTS (SELECT 1 FROM qa.clientes c WHERE c.cliente_id = b.cliente_id) THEN 'Cliente no existe'
              WHEN NOT EXISTS (SELECT 1 FROM qa.productos p WHERE p.producto_id = b.producto_id) THEN 'Producto no existe'
              WHEN b.cant_pedida IS NULL OR b.cant_pedida <= 0 THEN 'Cantidad pedida inválida' END AS motivo
  FROM b;
  CALL qa.guardar_errores(p_corrida, 'pedidos.csv');

  INSERT INTO qa.pedidos (numero_pedido, cliente_id, vendedor_id, fecha, estado)
  SELECT DISTINCT ON (numero_pedido) numero_pedido, cliente_id,
         (SELECT x.vendedor_id FROM qa.vendedores x WHERE x.vendedor_id = v.vendedor_id), fecha, estado
  FROM _v v WHERE motivo IS NULL ORDER BY numero_pedido, fila
  ON CONFLICT (numero_pedido) DO UPDATE SET
     cliente_id = EXCLUDED.cliente_id, vendedor_id = EXCLUDED.vendedor_id,
     fecha = EXCLUDED.fecha, estado = EXCLUDED.estado;

  DELETE FROM qa.pedidos_detalle d WHERE d.numero_pedido IN (SELECT numero_pedido FROM _v WHERE motivo IS NULL);
  INSERT INTO qa.pedidos_detalle (numero_pedido, linea, producto_id, cantidad_pedida, cantidad_despachada, precio_unitario)
  SELECT numero_pedido, row_number() OVER (PARTITION BY numero_pedido ORDER BY fila),
         producto_id, cant_pedida, cant_desp, precio
  FROM _v WHERE motivo IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  CALL qa.registrar_carga(p_corrida, 'pedidos.csv', 'pedidos', n);
END $$;

-- 4.8 Inventario (foto del día) -------------------------------------------
CREATE OR REPLACE PROCEDURE qa.cargar_inventario(p_corrida INT, p_fecha DATE)
LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM stg.inventario) THEN RETURN; END IF;
  DROP TABLE IF EXISTS _v;
  CREATE TEMP TABLE _v AS
  WITH b AS (
    SELECT s.fila, row_to_json(s)::text AS datos,
           qa.fn_codigo(stg.txt(s.referencia)) AS producto_id, upper(stg.txt(s.bodega)) AS bodega,
           stg.txt(s.lote) AS lote, stg.txt(s.ubicacion) AS ubicacion, stg.txt(s.presentacion) AS presentacion,
           stg.num_us(s.cantidad) AS cantidad, coalesce(stg.num_us(s.comprometido), 0) AS comprometido
    FROM stg.inventario s)
  SELECT b.*,
         CASE WHEN NOT EXISTS (SELECT 1 FROM qa.productos p WHERE p.producto_id = b.producto_id) THEN 'Producto no existe'
              WHEN b.bodega NOT IN ('VENTAS','PRODUCCION') OR b.bodega IS NULL THEN 'Bodega inválida (VENTAS o PRODUCCION)'
              WHEN b.cantidad IS NULL OR b.cantidad < 0 THEN 'Cantidad inválida' END AS motivo
  FROM b;
  CALL qa.guardar_errores(p_corrida, 'inventario.csv');

  DELETE FROM qa.inventario WHERE fecha_corte = p_fecha;          -- recargar el mismo día reemplaza
  INSERT INTO qa.inventario (fecha_corte, producto_id, bodega, lote, ubicacion, presentacion, cantidad, cantidad_comprometida)
  SELECT p_fecha, producto_id, bodega, lote, ubicacion, presentacion, sum(cantidad), sum(comprometido)
  FROM _v WHERE motivo IS NULL
  GROUP BY producto_id, bodega, lote, ubicacion, presentacion;
  GET DIAGNOSTICS n = ROW_COUNT;
  CALL qa.registrar_carga(p_corrida, 'inventario.csv', 'inventario', n);
END $$;

-- 4.9 Cartera (foto del día) ----------------------------------------------
CREATE OR REPLACE PROCEDURE qa.cargar_cartera(p_corrida INT, p_fecha DATE)
LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM stg.cartera) THEN RETURN; END IF;
  DROP TABLE IF EXISTS _v;
  CREATE TEMP TABLE _v AS
  WITH b AS (
    SELECT s.fila, row_to_json(s)::text AS datos,
           upper(stg.txt(s.documento)) AS numero_documento, stg.nit(s.nit) AS cliente_id,
           (SELECT x.vendedor_id FROM qa.vendedores x
             WHERE upper(btrim(x.nombre)) = upper(btrim(s.vendedor_nombre)) LIMIT 1) AS vendedor_id,
           stg.fecha(s.fecha_docto, 'MM/DD/YYYY') AS fecha_emision,
           stg.fecha(s.fecha_vcto,  'MM/DD/YYYY') AS fecha_vencimiento,
           stg.num_us(s.total) AS saldo
    FROM stg.cartera s)
  SELECT b.*,
         CASE WHEN b.numero_documento IS NULL THEN 'Documento vacío'
              WHEN NOT EXISTS (SELECT 1 FROM qa.clientes c WHERE c.cliente_id = b.cliente_id) THEN 'Cliente no existe'
              WHEN b.fecha_emision IS NULL OR b.fecha_vencimiento IS NULL THEN 'Fecha vacía o inválida'
              WHEN b.saldo IS NULL THEN 'Saldo inválido'
              WHEN row_number() OVER (PARTITION BY b.numero_documento ORDER BY b.fila) > 1 THEN 'Documento repetido en el archivo' END AS motivo
  FROM b;
  CALL qa.guardar_errores(p_corrida, 'cartera.csv');

  DELETE FROM qa.cartera WHERE fecha_corte = p_fecha;
  INSERT INTO qa.cartera (fecha_corte, numero_documento, cliente_id, vendedor_id, fecha_emision, fecha_vencimiento, saldo)
  SELECT p_fecha, numero_documento, cliente_id, vendedor_id, fecha_emision, fecha_vencimiento, saldo
  FROM _v WHERE motivo IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  CALL qa.registrar_carga(p_corrida, 'cartera.csv', 'cartera', n);
END $$;

-- 4.10 Cotizaciones (una fila por línea; separador ';', formato del ERP) ----
CREATE OR REPLACE PROCEDURE qa.cargar_cotizaciones(p_corrida INT)
LANGUAGE plpgsql AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM stg.cotizaciones) THEN RETURN; END IF;
  DROP TABLE IF EXISTS _v;
  CREATE TEMP TABLE _v AS
  WITH b AS (
    SELECT s.fila, row_to_json(s)::text AS datos,
           stg.txt(s.co) AS co, upper(stg.txt(s.numero)) AS numero_cotizacion,
           stg.fecha(s.fecha, 'DD/MM/YYYY') AS fecha,
           CASE WHEN lower(s.estado) LIKE 'en elabor%' THEN 'EN_ELABORACION'
                WHEN lower(s.estado) LIKE 'aprobad%'   THEN 'APROBADA'
                WHEN lower(s.estado) LIKE 'pedid%'     THEN 'PEDIDA'
                WHEN lower(s.estado) LIKE 'perdid%'    THEN 'PERDIDA' END AS estado,
           stg.nit(s.nit) AS cliente_id, upper(stg.txt(s.vendedor)) AS vendedor_id,
           qa.fn_codigo(stg.txt(s.referencia)) AS producto_id,
           stg.num_co(s.cantidad) AS cantidad, stg.num_co(s.precio) AS precio, stg.num_co(s.subtotal) AS subtotal
    FROM stg.cotizaciones s)
  SELECT b.*,
         CASE WHEN b.numero_cotizacion IS NULL THEN 'Número de cotización vacío'
              WHEN b.fecha IS NULL  THEN 'Fecha vacía o inválida'
              WHEN b.estado IS NULL THEN 'Estado desconocido'
              WHEN NOT EXISTS (SELECT 1 FROM qa.clientes c WHERE c.cliente_id = b.cliente_id) THEN 'Cliente no existe'
              WHEN NOT EXISTS (SELECT 1 FROM qa.productos p WHERE p.producto_id = b.producto_id) THEN 'Producto no existe'
              WHEN b.cantidad IS NULL OR b.cantidad <= 0 THEN 'Cantidad inválida'
              WHEN b.precio IS NULL THEN 'Precio inválido' END AS motivo
  FROM b;
  CALL qa.guardar_errores(p_corrida, 'cotizaciones.csv');

  -- Encabezado: no se tocan los campos que registra el área comercial (motivo de pérdida, observaciones)
  INSERT INTO qa.cotizaciones (numero_cotizacion, centro_operacion, cliente_id, vendedor_id, fecha,
                               estado_erp, valor_subtotal)
  SELECT numero_cotizacion, min(co), min(cliente_id),
         (SELECT x.vendedor_id FROM qa.vendedores x WHERE x.vendedor_id = min(v.vendedor_id)),
         min(fecha), min(estado), sum(coalesce(subtotal, cantidad * precio))
  FROM _v v WHERE motivo IS NULL GROUP BY numero_cotizacion
  ON CONFLICT (numero_cotizacion) DO UPDATE SET
     centro_operacion = EXCLUDED.centro_operacion, cliente_id = EXCLUDED.cliente_id,
     vendedor_id = EXCLUDED.vendedor_id, fecha = EXCLUDED.fecha,
     estado_erp = EXCLUDED.estado_erp, valor_subtotal = EXCLUDED.valor_subtotal;

  -- Igual que en facturas: la clasificación del precio se congela si la línea no cambió
  DROP TABLE IF EXISTS _ant;
  CREATE TEMP TABLE _ant AS
  SELECT numero_cotizacion AS doc, linea, producto_id, round(precio_unitario, 2) AS pu, precio_lista_referencia, tipo_precio
  FROM qa.cotizaciones_detalle WHERE numero_cotizacion IN (SELECT numero_cotizacion FROM _v WHERE motivo IS NULL);

  DELETE FROM qa.cotizaciones_detalle d WHERE d.numero_cotizacion IN (SELECT numero_cotizacion FROM _v WHERE motivo IS NULL);
  INSERT INTO qa.cotizaciones_detalle (numero_cotizacion, linea, producto_id, cantidad, precio_unitario,
                                       precio_lista_referencia, tipo_precio)
  SELECT x.numero_cotizacion, x.linea, x.producto_id, x.cantidad, x.precio,
         CASE WHEN a.doc IS NOT NULL THEN a.precio_lista_referencia
              ELSE qa.fn_precio_lista(x.cliente_id, x.producto_id, x.fecha) END,
         CASE WHEN a.doc IS NOT NULL THEN a.tipo_precio
              ELSE qa.fn_tipo_precio(x.cliente_id, x.producto_id, x.fecha, x.precio,
                                     qa.fn_precio_lista(x.cliente_id, x.producto_id, x.fecha)) END
  FROM (SELECT v.*, row_number() OVER (PARTITION BY v.numero_cotizacion ORDER BY v.fila) AS linea
        FROM _v v WHERE v.motivo IS NULL) x
  LEFT JOIN _ant a ON a.doc = x.numero_cotizacion AND a.linea = x.linea AND a.producto_id = x.producto_id
                  AND a.pu = round(x.precio, 2);
  GET DIAGNOSTICS n = ROW_COUNT;
  CALL qa.registrar_carga(p_corrida, 'cotizaciones.csv', 'cotizaciones', n);
END $$;

/* =====================================================================
   5. Orquestador: carga todo en el orden correcto, en UNA transacción
   Uso:  CALL qa.cargar_todo();                  -- corte = hoy
         CALL qa.cargar_todo('2026-10-21');      -- corte de otra fecha
   ===================================================================== */
CREATE OR REPLACE PROCEDURE qa.cargar_todo(p_fecha DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql AS $$
DECLARE c INT := nextval('qa.seq_corrida');
BEGIN
  CALL qa.cargar_vendedores(c);
  CALL qa.cargar_productos(c);
  CALL qa.cargar_tiempos(c);
  CALL qa.cargar_precios(c, p_fecha);
  CALL qa.cargar_clientes(c, p_fecha);
  CALL qa.cargar_pedidos(c);        -- antes que facturas: la factura toma el vendedor de su pedido
  CALL qa.cargar_facturas(c);
  CALL qa.cargar_inventario(c, p_fecha);
  CALL qa.cargar_cartera(c, p_fecha);
  CALL qa.cargar_cotizaciones(c);
  DROP TABLE IF EXISTS _v;
  RAISE NOTICE 'Corrida % terminada (corte %). Revisa qa.v_resumen_ultima_carga y qa.v_errores_ultima_carga.', c, p_fecha;
END $$;

/* ---------------------------------------------------------------------
   6. Vistas para revisar la carga
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW qa.v_resumen_ultima_carga AS
SELECT corrida, archivo, tabla_destino, filas AS filas_cargadas, filas_error, fecha_carga
FROM qa.log_cargas
WHERE corrida = (SELECT max(corrida) FROM qa.log_cargas)
ORDER BY id_carga;

CREATE OR REPLACE VIEW qa.v_errores_ultima_carga AS
SELECT archivo, linea, nivel, motivo, datos
FROM qa.carga_errores
WHERE corrida = (SELECT max(corrida) FROM qa.log_cargas)   -- la última corrida, aunque no haya tenido errores
ORDER BY archivo, linea;

-- Para mostrar en el cotizador "Datos actualizados al ..."
CREATE OR REPLACE VIEW qa.v_estado_datos AS
SELECT max(fecha_carga) AS ultima_carga,
       (SELECT max(fecha_corte) FROM qa.inventario) AS corte_inventario,
       (SELECT max(fecha_corte) FROM qa.cartera)    AS corte_cartera,
       (SELECT max(fecha)       FROM qa.facturas)   AS ultima_factura
FROM qa.log_cargas WHERE corrida IS NOT NULL;


/* ---------------------------------------------------------------------
   7. Cliente sucesor (una empresa que cambia de NIT)
   Uso:  CALL qa.pr_enlazar_sucesor('NIT_ANTIGUO', 'NIT_NUEVO');
   El NIT antiguo queda INACTIVO y apuntando al nuevo. Para el análisis y el
   forecast, qa.v_clientes_consolidado agrupa ambos bajo el NIT vigente.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE qa.pr_enlazar_sucesor(p_antiguo VARCHAR, p_nuevo VARCHAR)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_antiguo = p_nuevo THEN RAISE EXCEPTION 'El NIT antiguo y el nuevo son el mismo'; END IF;
  IF NOT EXISTS (SELECT 1 FROM qa.clientes WHERE cliente_id = p_nuevo) THEN
    RAISE EXCEPTION 'No existe el cliente nuevo %', p_nuevo; END IF;
  UPDATE qa.clientes SET cliente_sucesor = p_nuevo, estado = 'INACTIVO', actualizado_en = now()
  WHERE cliente_id = p_antiguo;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el cliente antiguo %', p_antiguo; END IF;
END $$;

CREATE OR REPLACE VIEW qa.v_clientes_consolidado AS
WITH RECURSIVE cadena AS (
  SELECT cliente_id, cliente_id AS cliente_vigente, cliente_sucesor, 0 AS saltos FROM qa.clientes
  UNION ALL
  SELECT c.cliente_id, s.cliente_id, s.cliente_sucesor, c.saltos + 1
  FROM cadena c JOIN qa.clientes s ON s.cliente_id = c.cliente_sucesor
  WHERE c.saltos < 10)
SELECT DISTINCT ON (cliente_id) cliente_id, cliente_vigente
FROM cadena ORDER BY cliente_id, saltos DESC;
COMMENT ON VIEW qa.v_clientes_consolidado IS
  'Cada NIT con el NIT vigente al que pertenece (si cambió de NIT). Úsala para sumar ventas por cliente real.';
