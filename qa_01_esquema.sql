/* =====================================================================
   QUÍMICA ANDINA S.A.S. (ficticia) — BASE DE DATOS COMERCIAL
   Script 01: Esquema (tablas, índices, vistas y funciones)
   Motor: PostgreSQL 14+   |   Ejecutar completo en una base NUEVA
   ---------------------------------------------------------------------
   Diseñado para recibir exportaciones CSV de un ERP (genérico).
   Principios:
     - Maestros (vendedores, clientes, contactos, productos): se actualizan.
     - Precios: se agregan filas con fecha (historial), no se sobrescriben.
     - Transacciones (cotizaciones, pedidos, facturas): se acumulan.
     - Fotos diarias (inventario, cartera): se guardan por fecha de corte.
     - Códigos de producto: texto, numéricos rellenados a 4 dígitos ("0007").
   ===================================================================== */

CREATE SCHEMA IF NOT EXISTS qa;
SET search_path TO qa, public;

/* ---------------------------------------------------------------------
   0. PARÁMETROS Y UTILIDADES
   --------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS parametros (
    clave        VARCHAR(50)  PRIMARY KEY,
    valor        VARCHAR(100) NOT NULL,
    descripcion  TEXT
);
INSERT INTO parametros VALUES
 ('vigencia_cotizacion_dias','30','Días tras los cuales una cotización APROBADA sin pedido se considera VENCIDA'),
 ('dias_stock_antiguo','365','Antigüedad de lote (días) a partir de la cual se alerta "stock antiguo"')
ON CONFLICT (clave) DO NOTHING;

-- Normaliza códigos de producto: "7" -> "0007", " 14 " -> "0014", "480E" -> "0480E"
CREATE OR REPLACE FUNCTION fn_codigo(p TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN btrim(p) ~ '^\d+$'         THEN lpad(btrim(p), 4, '0')
              WHEN upper(btrim(p)) ~ '^\d+[A-Z]$' THEN lpad(substring(btrim(p) FROM '^\d+'), 4, '0')
                                                      || upper(right(btrim(p), 1))      -- 480E -> 0480E
              ELSE upper(btrim(p)) END;
$$;

-- Fecha de fabricación a partir del lote (20251023003 -> 2025-10-23). NULL si no aplica.
CREATE OR REPLACE FUNCTION fn_fecha_lote(p TEXT) RETURNS DATE
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p ~ '^(19|20)\d{6}' THEN
     RETURN to_date(substr(p,1,8), 'YYYYMMDD');
  END IF;
  RETURN NULL;
EXCEPTION WHEN others THEN
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION fn_parametro_int(p_clave TEXT) RETURNS INTEGER
LANGUAGE sql STABLE AS $$
  SELECT valor::int FROM qa.parametros WHERE clave = p_clave;
$$;

/* ---------------------------------------------------------------------
   1. MAESTROS
   --------------------------------------------------------------------- */

-- Equipo comercial de la empresa
CREATE TABLE IF NOT EXISTS vendedores (
    vendedor_id  VARCHAR(20)  PRIMARY KEY,           -- código en el ERP
    nombre       VARCHAR(150) NOT NULL,
    email        VARCHAR(150),
    telefono     VARCHAR(20),
    zona         VARCHAR(80),
    activo       BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS clientes (
    cliente_id          VARCHAR(20)  PRIMARY KEY,    -- NIT o cédula, sin puntos ni comas
    nombre              VARCHAR(200) NOT NULL,
    estado              VARCHAR(10)  NOT NULL DEFAULT 'ACTIVO'
                        CHECK (estado IN ('ACTIVO','INACTIVO','BLOQUEADO')),
    ciudad              VARCHAR(80),
    segmento            VARCHAR(12)  CHECK (segmento IN ('EMPRESA','EMPRENDEDOR')),
    lista_precio        SMALLINT     NOT NULL DEFAULT 1 CHECK (lista_precio BETWEEN 1 AND 4),
    vendedor_id         VARCHAR(20)  REFERENCES vendedores(vendedor_id),
    condicion_pago_dias INTEGER,                     -- opcional: 0 = contado
    cupo_credito        NUMERIC(16,2),               -- opcional
    actualizado_en      TIMESTAMP    NOT NULL DEFAULT now()
);

-- Personas del lado del cliente
CREATE TABLE IF NOT EXISTS contactos (
    contacto_id   SERIAL        PRIMARY KEY,
    apellido      VARCHAR(80)   NOT NULL,
    nombre        VARCHAR(80)   NOT NULL,
    cliente_id    VARCHAR(20)   NOT NULL REFERENCES clientes(cliente_id),
    email         VARCHAR(150)  UNIQUE,
    telefono_1    VARCHAR(20),
    telefono_2    VARCHAR(20),
    cargo         VARCHAR(100),
    rol           VARCHAR(10)   CHECK (rol IN ('COMPRAS','TECNICO','DECISOR','CARTERA','OTRO')),
    es_principal  BOOLEAN       NOT NULL DEFAULT FALSE,
    activo        BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE IF NOT EXISTS productos (
    producto_id             VARCHAR(20)  PRIMARY KEY,      -- normalizado con fn_codigo
    nombre                  VARCHAR(250) NOT NULL,
    categoria               VARCHAR(80),
    familia                 VARCHAR(10),                    -- A / B / C (sale de la columna Línea: "Línea A")
    tipo                    VARCHAR(12)  NOT NULL DEFAULT 'SIN_TIPO'
                            CHECK (tipo IN ('FABRICADO','DISTRIBUIDO','SIN_TIPO')),
    producto_base           VARCHAR(20)  REFERENCES productos(producto_id), -- 1569E -> 1569
    unidad_medida           VARCHAR(10)  NOT NULL DEFAULT 'KG',
    venta_minima            NUMERIC(12,3),                  -- expresada en unidad_medida (250 g = 0.25 KG)
    tiempo_fabricacion_dias INTEGER,                        -- lo define Producción (no está en el ERP)
    fecha_lanzamiento       DATE,                           -- clave para productos nuevos en el pronóstico
    estado                  VARCHAR(14)  NOT NULL DEFAULT 'ACTIVO'
                            CHECK (estado IN ('ACTIVO','DESCONTINUADO')),
    comentarios             TEXT,                           -- "Promocionar stock", "Grado especial"...
    actualizado_en          TIMESTAMP    NOT NULL DEFAULT now(),
    CHECK (producto_id = fn_codigo(producto_id))
);

/* ---------------------------------------------------------------------
   2. PRECIOS
   --------------------------------------------------------------------- */

-- Precios guía: una fila por producto y fecha de vigencia (formato ancho)
CREATE TABLE IF NOT EXISTS precios (
    producto_id    VARCHAR(20)   NOT NULL REFERENCES productos(producto_id),
    vigente_desde  DATE          NOT NULL,
    lista_1        NUMERIC(16,2),
    lista_2        NUMERIC(16,2),
    lista_3        NUMERIC(16,2),
    lista_4        NUMERIC(16,2),
    PRIMARY KEY (producto_id, vigente_desde)
);

-- Acuerdos de precio con un cliente que se sostienen en el tiempo
CREATE TABLE IF NOT EXISTS precios_especiales (
    id               SERIAL        PRIMARY KEY,
    cliente_id       VARCHAR(20)   NOT NULL REFERENCES clientes(cliente_id),
    producto_id      VARCHAR(20)   NOT NULL REFERENCES productos(producto_id),
    precio_especial  NUMERIC(16,2) NOT NULL CHECK (precio_especial >= 0),
    vigente_desde    DATE          NOT NULL,
    vigente_hasta    DATE,                              -- NULL = sin fecha de fin
    CHECK (vigente_hasta IS NULL OR vigente_hasta >= vigente_desde)
);
-- Un solo acuerdo abierto (sin fecha de fin) por cliente y producto
CREATE UNIQUE INDEX IF NOT EXISTS ux_precio_especial_abierto
    ON precios_especiales (cliente_id, producto_id) WHERE vigente_hasta IS NULL;

/* ---------------------------------------------------------------------
   3. FOTOS DIARIAS
   --------------------------------------------------------------------- */

-- Inventario por bodega, lote, ubicación y presentación
CREATE TABLE IF NOT EXISTS inventario (
    id                     BIGSERIAL     PRIMARY KEY,
    fecha_corte            DATE          NOT NULL,
    producto_id            VARCHAR(20)   NOT NULL REFERENCES productos(producto_id),
    bodega                 VARCHAR(12)   NOT NULL CHECK (bodega IN ('VENTAS','PRODUCCION')),
                                         -- VENTAS = almacén de despacho · PRODUCCION = en producción
    lote                   VARCHAR(40),
    ubicacion              VARCHAR(20),
    presentacion           VARCHAR(30),  -- "25 KG"
    cantidad               NUMERIC(14,3) NOT NULL DEFAULT 0,
    cantidad_comprometida  NUMERIC(14,3) NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_inventario
    ON inventario (fecha_corte, producto_id, bodega,
                   coalesce(lote,''), coalesce(ubicacion,''), coalesce(presentacion,''));

-- Cartera: una fila por documento pendiente en cada fecha de corte
CREATE TABLE IF NOT EXISTS cartera (
    fecha_corte        DATE          NOT NULL,
    numero_documento   VARCHAR(30)   NOT NULL,
    cliente_id         VARCHAR(20)   NOT NULL REFERENCES clientes(cliente_id),
    vendedor_id        VARCHAR(20)   REFERENCES vendedores(vendedor_id),
    fecha_emision      DATE          NOT NULL,
    fecha_vencimiento  DATE          NOT NULL,
    valor_original     NUMERIC(16,2),             -- opcional (el reporte de cartera no lo trae)
    saldo              NUMERIC(16,2) NOT NULL,
    PRIMARY KEY (fecha_corte, numero_documento)
);

/* ---------------------------------------------------------------------
   4. TRANSACCIONES
   Los enlaces entre documentos (cotización→pedido→factura) no llevan
   llave foránea: el historial cargado puede estar incompleto y no debe
   bloquear la carga.
   --------------------------------------------------------------------- */

CREATE TABLE IF NOT EXISTS cotizaciones (
    numero_cotizacion  VARCHAR(30)   PRIMARY KEY,           -- CTZ-00005982
    centro_operacion   VARCHAR(10),                         -- sede o centro de operación (001)
    cliente_id         VARCHAR(20)   NOT NULL REFERENCES clientes(cliente_id),
    vendedor_id        VARCHAR(20)   REFERENCES vendedores(vendedor_id),
    fecha              DATE          NOT NULL,
    moneda             CHAR(3)       NOT NULL DEFAULT 'COP',
    estado_erp       VARCHAR(15)   NOT NULL
                       CHECK (estado_erp IN ('EN_ELABORACION','APROBADA','PEDIDA','PERDIDA')),
    motivo_perdida     VARCHAR(20)   CHECK (motivo_perdida IN
                       ('PRECIO','TIEMPO_ENTREGA','SIN_INVENTARIO','COMPETENCIA','OTRO')),
    numero_pedido      VARCHAR(30),
    valor_bruto        NUMERIC(16,2),
    valor_descuentos   NUMERIC(16,2),
    valor_subtotal     NUMERIC(16,2),                       -- sin IVA: base para análisis
    valor_impuestos    NUMERIC(16,2),
    valor_neto         NUMERIC(16,2),
    observaciones      TEXT
);

CREATE TABLE IF NOT EXISTS cotizaciones_detalle (
    numero_cotizacion        VARCHAR(30)   NOT NULL REFERENCES cotizaciones(numero_cotizacion) ON DELETE CASCADE,
    linea                    INTEGER       NOT NULL,
    producto_id              VARCHAR(20)   NOT NULL REFERENCES productos(producto_id),
    cantidad                 NUMERIC(14,3) NOT NULL CHECK (cantidad > 0),
    precio_unitario          NUMERIC(16,2) NOT NULL,
    precio_lista_referencia  NUMERIC(16,2),
    tipo_precio              VARCHAR(10)   CHECK (tipo_precio IN ('LISTA','ESPECIAL','UNICA_VEZ')),
    PRIMARY KEY (numero_cotizacion, linea)
);

CREATE TABLE IF NOT EXISTS pedidos (
    numero_pedido               VARCHAR(30)  PRIMARY KEY,
    cliente_id                  VARCHAR(20)  NOT NULL REFERENCES clientes(cliente_id),
    vendedor_id                 VARCHAR(20)  REFERENCES vendedores(vendedor_id),
    numero_cotizacion           VARCHAR(30),
    fecha                       DATE         NOT NULL,
    fecha_entrega_comprometida  DATE,
    estado                      VARCHAR(8)   NOT NULL DEFAULT 'ABIERTO'
                                CHECK (estado IN ('ABIERTO','PARCIAL','CERRADO','ANULADO')),
    observaciones               TEXT
);

CREATE TABLE IF NOT EXISTS pedidos_detalle (
    numero_pedido        VARCHAR(30)   NOT NULL REFERENCES pedidos(numero_pedido) ON DELETE CASCADE,
    linea                INTEGER       NOT NULL,
    producto_id          VARCHAR(20)   NOT NULL REFERENCES productos(producto_id),
    cantidad_pedida      NUMERIC(14,3) NOT NULL CHECK (cantidad_pedida > 0),
    cantidad_despachada  NUMERIC(14,3) NOT NULL DEFAULT 0,
    precio_unitario      NUMERIC(16,2),
    PRIMARY KEY (numero_pedido, linea)
);

CREATE TABLE IF NOT EXISTS facturas (
    numero_factura     VARCHAR(30)  PRIMARY KEY,           -- FE-00034168
    cliente_id         VARCHAR(20)  NOT NULL REFERENCES clientes(cliente_id),
    vendedor_id        VARCHAR(20)  REFERENCES vendedores(vendedor_id),
    numero_pedido      VARCHAR(30),
    fecha              DATE         NOT NULL,
    fecha_vencimiento  DATE,
    tipo               CHAR(2)      NOT NULL DEFAULT 'FV' CHECK (tipo IN ('FV','NC'))
);

CREATE TABLE IF NOT EXISTS facturas_detalle (
    numero_factura           VARCHAR(30)   NOT NULL REFERENCES facturas(numero_factura) ON DELETE CASCADE,
    linea                    INTEGER       NOT NULL,
    producto_id              VARCHAR(20)   NOT NULL REFERENCES productos(producto_id),
    lote                     VARCHAR(40),
    cantidad                 NUMERIC(14,3) NOT NULL,       -- negativa en notas crédito
    valor_subtotal           NUMERIC(16,2) NOT NULL,       -- sin IVA, como viene de la fuente
    precio_unitario          NUMERIC(16,2) GENERATED ALWAYS AS
                             (CASE WHEN cantidad <> 0 THEN round(valor_subtotal / cantidad, 2) END) STORED,
    precio_lista_referencia  NUMERIC(16,2),
    tipo_precio              VARCHAR(10)   CHECK (tipo_precio IN ('LISTA','ESPECIAL','UNICA_VEZ')),
    PRIMARY KEY (numero_factura, linea)
);

/* ---------------------------------------------------------------------
   5. CONTROL DE CARGAS
   --------------------------------------------------------------------- */
CREATE TABLE IF NOT EXISTS log_cargas (
    id_carga       SERIAL       PRIMARY KEY,
    tabla_destino  VARCHAR(60)  NOT NULL,
    archivo        VARCHAR(255),
    filas          INTEGER,
    fecha_carga    TIMESTAMP    NOT NULL DEFAULT now(),
    observaciones  TEXT
);

/* ---------------------------------------------------------------------
   6. ÍNDICES
   --------------------------------------------------------------------- */
CREATE INDEX IF NOT EXISTS ix_clientes_nombre  ON clientes (lower(nombre));
CREATE INDEX IF NOT EXISTS ix_contactos_cli    ON contactos (cliente_id);
CREATE INDEX IF NOT EXISTS ix_prod_base        ON productos (producto_base);
CREATE INDEX IF NOT EXISTS ix_pesp_cli_prod    ON precios_especiales (cliente_id, producto_id);
CREATE INDEX IF NOT EXISTS ix_inv_prod         ON inventario (producto_id, fecha_corte);
CREATE INDEX IF NOT EXISTS ix_cartera_cli      ON cartera (cliente_id, fecha_corte);
CREATE INDEX IF NOT EXISTS ix_cot_cli          ON cotizaciones (cliente_id, fecha);
CREATE INDEX IF NOT EXISTS ix_cotd_prod        ON cotizaciones_detalle (producto_id);
CREATE INDEX IF NOT EXISTS ix_ped_cli          ON pedidos (cliente_id, fecha);
CREATE INDEX IF NOT EXISTS ix_pedd_prod        ON pedidos_detalle (producto_id);
CREATE INDEX IF NOT EXISTS ix_fac_cli          ON facturas (cliente_id, fecha);
CREATE INDEX IF NOT EXISTS ix_fac_fecha        ON facturas (fecha);
CREATE INDEX IF NOT EXISTS ix_facd_prod        ON facturas_detalle (producto_id);

/* =====================================================================
   7. VISTAS DE NEGOCIO
   ===================================================================== */

-- 7.1 Precio guía vigente hoy (una fila por producto)
CREATE OR REPLACE VIEW v_precio_vigente AS
SELECT DISTINCT ON (producto_id)
       producto_id, vigente_desde, lista_1, lista_2, lista_3, lista_4
FROM precios
WHERE vigente_desde <= CURRENT_DATE
ORDER BY producto_id, vigente_desde DESC;

-- 7.2 Precio especial vigente hoy
CREATE OR REPLACE VIEW v_precio_especial_vigente AS
SELECT DISTINCT ON (cliente_id, producto_id)
       cliente_id, producto_id, precio_especial, vigente_desde, vigente_hasta
FROM precios_especiales
WHERE vigente_desde <= CURRENT_DATE
  AND (vigente_hasta IS NULL OR vigente_hasta >= CURRENT_DATE)
ORDER BY cliente_id, producto_id, vigente_desde DESC;

-- 7.3 Inventario al último corte, por producto
CREATE OR REPLACE VIEW v_inventario_actual AS
WITH ult AS (SELECT max(fecha_corte) AS fc FROM inventario),
     inv AS (SELECT i.* FROM inventario i JOIN ult ON i.fecha_corte = ult.fc)
SELECT p.producto_id, p.nombre, p.tipo,
       coalesce(sum(inv.cantidad) FILTER (WHERE inv.bodega='VENTAS'),0)              AS almacen,
       coalesce(sum(inv.cantidad_comprometida),0)                                   AS comprometido,
       coalesce(sum(inv.cantidad) FILTER (WHERE inv.bodega='VENTAS'),0)
         - coalesce(sum(inv.cantidad_comprometida),0)                               AS disponible,
       coalesce(sum(inv.cantidad) FILTER (WHERE inv.bodega='PRODUCCION'),0)               AS en_produccion,
       min(fn_fecha_lote(inv.lote)) FILTER (WHERE inv.cantidad > 0)                 AS fecha_lote_mas_antiguo,
       CURRENT_DATE - min(fn_fecha_lote(inv.lote)) FILTER (WHERE inv.cantidad > 0)  AS dias_lote_mas_antiguo,
       p.tiempo_fabricacion_dias,
       (SELECT fc FROM ult)                                                          AS fecha_corte
FROM productos p
LEFT JOIN inv USING (producto_id)
GROUP BY p.producto_id, p.nombre, p.tipo, p.tiempo_fabricacion_dias;

-- 7.4 Cartera por cliente con edades de mora (último corte)
CREATE OR REPLACE VIEW v_cartera_cliente AS
WITH ult AS (SELECT max(fecha_corte) AS fc FROM cartera),
     doc AS (SELECT c.*, (ult.fc - c.fecha_vencimiento) AS dias_vencido
             FROM cartera c JOIN ult ON c.fecha_corte = ult.fc
             WHERE c.saldo <> 0)
SELECT cliente_id,
       sum(saldo)                                               AS saldo_total,
       sum(saldo) FILTER (WHERE dias_vencido <= 0)              AS corriente,
       sum(saldo) FILTER (WHERE dias_vencido BETWEEN 1  AND 30) AS vencido_1_30,
       sum(saldo) FILTER (WHERE dias_vencido BETWEEN 31 AND 60) AS vencido_31_60,
       sum(saldo) FILTER (WHERE dias_vencido BETWEEN 61 AND 90) AS vencido_61_90,
       sum(saldo) FILTER (WHERE dias_vencido > 90)              AS vencido_mas_90,
       coalesce(sum(saldo) FILTER (WHERE dias_vencido > 0), 0)  AS vencido_total,
       greatest(max(dias_vencido), 0)                           AS max_dias_vencido,
       count(*)                                                 AS documentos,
       max(fecha_corte)                                         AS fecha_corte
FROM doc
GROUP BY cliente_id;

-- 7.5 Líneas de pedido pendientes por despachar
CREATE OR REPLACE VIEW v_pedidos_vigentes AS
SELECT p.numero_pedido, p.cliente_id, p.fecha, p.fecha_entrega_comprometida, p.estado,
       d.linea, d.producto_id, pr.nombre AS producto,
       d.cantidad_pedida, d.cantidad_despachada,
       d.cantidad_pedida - d.cantidad_despachada                         AS cantidad_pendiente,
       (d.cantidad_pedida - d.cantidad_despachada) * d.precio_unitario   AS valor_pendiente
FROM pedidos p
JOIN pedidos_detalle d USING (numero_pedido)
JOIN productos pr USING (producto_id)
WHERE p.estado IN ('ABIERTO','PARCIAL')
  AND d.cantidad_pedida > d.cantidad_despachada;

-- 7.6 Cotizaciones con su estado comercial
CREATE OR REPLACE VIEW v_cotizaciones AS
SELECT c.*,
       CASE
         WHEN c.estado_erp = 'EN_ELABORACION' THEN 'BORRADOR'
         WHEN c.estado_erp = 'PEDIDA'         THEN 'GANADA'
         WHEN c.estado_erp = 'PERDIDA'        THEN 'PERDIDA'
         WHEN c.motivo_perdida IS NOT NULL      THEN 'PERDIDA'
         WHEN CURRENT_DATE - c.fecha > fn_parametro_int('vigencia_cotizacion_dias') THEN 'VENCIDA'
         ELSE 'ABIERTA'
       END                                   AS estado_comercial,
       CURRENT_DATE - c.fecha                AS dias_desde_emision
FROM cotizaciones c;

-- 7.7 Ventas línea a línea (base de todo el análisis)
CREATE OR REPLACE VIEW v_ventas AS
SELECT f.numero_factura, f.fecha, f.cliente_id, f.vendedor_id, f.tipo, f.numero_pedido,
       d.linea, d.producto_id, coalesce(p.producto_base, d.producto_id) AS producto_agrupado,
       d.lote, d.cantidad, d.valor_subtotal, d.precio_unitario,
       d.precio_lista_referencia, d.tipo_precio,
       CASE WHEN d.precio_lista_referencia > 0
            THEN round(100.0 * (d.precio_unitario / d.precio_lista_referencia - 1), 1) END
                                                                  AS dif_vs_lista_pct
FROM facturas f
JOIN facturas_detalle d USING (numero_factura)
JOIN productos p ON p.producto_id = d.producto_id;

-- 7.8 Última compra de cada producto por cliente
CREATE OR REPLACE VIEW v_ultima_compra AS
SELECT DISTINCT ON (cliente_id, producto_id)
       cliente_id, producto_id,
       fecha            AS fecha_ultima_compra,
       cantidad         AS cantidad_ultima_compra,
       precio_unitario  AS precio_ultima_compra,
       CURRENT_DATE - fecha AS dias_desde_ultima_compra
FROM v_ventas
WHERE tipo = 'FV'
ORDER BY cliente_id, producto_id, fecha DESC;

-- 7.9 FICHA ÚNICA DE CLIENTE
CREATE OR REPLACE VIEW v_ficha_cliente AS
SELECT c.cliente_id, c.nombre, c.estado, c.ciudad, c.segmento,
       c.lista_precio, v.nombre                         AS vendedor,
       c.condicion_pago_dias, c.cupo_credito,
       (SELECT count(*) FROM contactos k WHERE k.cliente_id = c.cliente_id AND k.activo) AS contactos_activos,
       (SELECT count(*) FROM v_precio_especial_vigente e WHERE e.cliente_id = c.cliente_id) AS precios_especiales,
       coalesce(ca.saldo_total, 0)                      AS cartera_saldo,
       coalesce(ca.vencido_total, 0)                    AS cartera_vencida,
       coalesce(ca.max_dias_vencido, 0)                 AS max_dias_vencido,
       c.cupo_credito - coalesce(ca.saldo_total, 0)     AS cupo_disponible,
       coalesce(pv.pedidos_vigentes, 0)                 AS pedidos_vigentes,
       coalesce(pv.valor_pendiente, 0)                  AS valor_pedidos_pendiente,
       coalesce(co.abiertas, 0)                         AS cotizaciones_abiertas,
       ve.fecha_ultima_factura,
       coalesce(ve.facturas_90d, 0)                     AS facturas_ultimos_90_dias,
       coalesce(ve.ventas_90d, 0)                       AS ventas_ultimos_90_dias,
       coalesce(ve.ventas_12m, 0)                       AS ventas_ultimos_12_meses
FROM clientes c
LEFT JOIN vendedores v USING (vendedor_id)
LEFT JOIN v_cartera_cliente ca USING (cliente_id)
LEFT JOIN (SELECT cliente_id, count(DISTINCT numero_pedido) AS pedidos_vigentes,
                  sum(valor_pendiente) AS valor_pendiente
           FROM v_pedidos_vigentes GROUP BY cliente_id) pv USING (cliente_id)
LEFT JOIN (SELECT cliente_id, count(*) AS abiertas
           FROM v_cotizaciones WHERE estado_comercial = 'ABIERTA'
           GROUP BY cliente_id) co USING (cliente_id)
LEFT JOIN (SELECT cliente_id,
                  max(fecha) FILTER (WHERE tipo='FV')                                           AS fecha_ultima_factura,
                  count(DISTINCT numero_factura) FILTER (WHERE tipo='FV' AND fecha >= CURRENT_DATE - 90) AS facturas_90d,
                  sum(valor_subtotal) FILTER (WHERE fecha >= CURRENT_DATE - 90)                 AS ventas_90d,
                  sum(valor_subtotal) FILTER (WHERE fecha >= CURRENT_DATE - INTERVAL '12 months') AS ventas_12m
           FROM v_ventas GROUP BY cliente_id) ve USING (cliente_id);

-- 7.10 Serie mensual por producto (insumo del pronóstico)
--      Incluye meses sin venta en cero; agrupa variantes "E" en su producto base.
CREATE OR REPLACE VIEW v_ventas_mensuales_producto AS
WITH rango AS (SELECT date_trunc('month', min(fecha))::date AS ini,
                      date_trunc('month', max(fecha))::date AS fin FROM v_ventas),
     meses AS (SELECT generate_series(ini, fin, INTERVAL '1 month')::date AS mes FROM rango),
     base  AS (SELECT date_trunc('month', fecha)::date AS mes, producto_agrupado AS producto_id,
                      sum(cantidad) AS cantidad, sum(valor_subtotal) AS valor,
                      count(DISTINCT cliente_id) AS clientes, count(DISTINCT numero_factura) AS facturas,
                      count(*) FILTER (WHERE tipo_precio = 'UNICA_VEZ') AS lineas_unica_vez
               FROM v_ventas GROUP BY 1, 2)
SELECT m.mes, p.producto_id, p.nombre, p.familia, p.tipo,
       coalesce(b.cantidad, 0) AS cantidad,
       coalesce(b.valor, 0)    AS valor,
       coalesce(b.clientes, 0) AS clientes,
       coalesce(b.facturas, 0) AS facturas,
       coalesce(b.lineas_unica_vez, 0) AS lineas_unica_vez
FROM meses m
CROSS JOIN productos p
LEFT JOIN base b ON b.mes = m.mes AND b.producto_id = p.producto_id
WHERE p.producto_base IS NULL
  AND m.mes >= date_trunc('month', coalesce(p.fecha_lanzamiento, '1900-01-01'::date));

-- 7.11 Embudo de cotizaciones por mes y vendedor
CREATE OR REPLACE VIEW v_embudo_cotizaciones AS
SELECT date_trunc('month', fecha)::date AS mes, vendedor_id,
       count(*) FILTER (WHERE estado_comercial <> 'BORRADOR')  AS cotizaciones,
       count(*) FILTER (WHERE estado_comercial = 'GANADA')     AS ganadas,
       count(*) FILTER (WHERE estado_comercial = 'PERDIDA')    AS perdidas,
       count(*) FILTER (WHERE estado_comercial = 'VENCIDA')    AS vencidas,
       count(*) FILTER (WHERE estado_comercial = 'ABIERTA')    AS abiertas,
       round(100.0 * count(*) FILTER (WHERE estado_comercial = 'GANADA')
             / nullif(count(*) FILTER (WHERE estado_comercial IN ('GANADA','PERDIDA','VENCIDA')), 0), 1)
                                                               AS tasa_cierre_pct,
       sum(valor_subtotal) FILTER (WHERE estado_comercial <> 'BORRADOR') AS valor_cotizado,
       sum(valor_subtotal) FILTER (WHERE estado_comercial = 'GANADA')    AS valor_ganado
FROM v_cotizaciones
GROUP BY 1, 2;

-- 7.12 Motivos de pérdida
CREATE OR REPLACE VIEW v_motivos_perdida AS
SELECT coalesce(motivo_perdida, 'SIN_REGISTRAR') AS motivo,
       count(*) AS cotizaciones, sum(valor_subtotal) AS valor
FROM v_cotizaciones
WHERE estado_comercial IN ('PERDIDA','VENCIDA')
GROUP BY 1;

/* =====================================================================
   8. COTIZACIÓN RÁPIDA
   Uso: SELECT * FROM qa.fn_cotizacion_rapida('901802759', ARRAY['7','0053']);
        SELECT * FROM qa.fn_cotizacion_rapida('901802759');  -- productos que ya compra
   Los códigos se normalizan solos ("7" = "0007").
   ===================================================================== */
CREATE OR REPLACE FUNCTION fn_cotizacion_rapida(
        p_cliente   VARCHAR,
        p_productos TEXT[] DEFAULT NULL)
RETURNS TABLE (
        producto_id              VARCHAR,
        producto                 VARCHAR,
        tipo                     VARCHAR,
        lista_cliente            SMALLINT,
        precio_lista             NUMERIC,
        precio_especial          NUMERIC,
        precio_ultima_compra     NUMERIC,
        fecha_ultima_compra      DATE,
        ultima_vs_lista_pct      NUMERIC,
        venta_minima             NUMERIC,
        disponible               NUMERIC,
        en_produccion            NUMERIC,
        pendiente_en_pedidos     NUMERIC,
        tiempo_fabricacion_dias  INTEGER,
        alertas                  TEXT)
LANGUAGE sql STABLE AS
$$
WITH cli AS (
        SELECT c.*, coalesce(ca.vencido_total,0) AS vencido, coalesce(ca.max_dias_vencido,0) AS dias_venc
        FROM qa.clientes c LEFT JOIN qa.v_cartera_cliente ca USING (cliente_id)
        WHERE c.cliente_id = p_cliente),
     prods AS (
        SELECT qa.fn_codigo(x) AS producto_id FROM unnest(p_productos) x WHERE p_productos IS NOT NULL
        UNION
        SELECT u.producto_id FROM qa.v_ultima_compra u
        WHERE p_productos IS NULL AND u.cliente_id = p_cliente),
     base AS (
        SELECT pr.producto_id, pr.nombre, pr.tipo, pr.venta_minima, pr.tiempo_fabricacion_dias,
               pr.unidad_medida, cli.lista_precio, cli.estado AS estado_cliente, cli.vencido, cli.dias_venc,
               CASE cli.lista_precio WHEN 1 THEN pv.lista_1 WHEN 2 THEN pv.lista_2
                                     WHEN 3 THEN pv.lista_3 WHEN 4 THEN pv.lista_4 END AS precio_lista,
               pe.precio_especial,
               uc.precio_ultima_compra, uc.fecha_ultima_compra,
               inv.disponible, inv.en_produccion, inv.dias_lote_mas_antiguo,
               ped.pendiente
        FROM prods
        JOIN qa.productos pr USING (producto_id)
        CROSS JOIN cli
        LEFT JOIN qa.v_precio_vigente pv ON pv.producto_id = pr.producto_id
        LEFT JOIN qa.v_precio_especial_vigente pe
               ON pe.cliente_id = cli.cliente_id AND pe.producto_id = pr.producto_id
        LEFT JOIN qa.v_ultima_compra uc
               ON uc.cliente_id = cli.cliente_id AND uc.producto_id = pr.producto_id
        LEFT JOIN qa.v_inventario_actual inv ON inv.producto_id = pr.producto_id
        LEFT JOIN (SELECT v.producto_id, sum(v.cantidad_pendiente) AS pendiente
                   FROM qa.v_pedidos_vigentes v WHERE v.cliente_id = p_cliente
                   GROUP BY 1) ped ON ped.producto_id = pr.producto_id)
SELECT producto_id, nombre, tipo, lista_precio,
       precio_lista, precio_especial, precio_ultima_compra, fecha_ultima_compra,
       CASE WHEN precio_lista > 0 AND precio_ultima_compra IS NOT NULL
            THEN round(100.0 * (precio_ultima_compra / precio_lista - 1), 1) END,
       venta_minima,
       coalesce(disponible, 0), coalesce(en_produccion, 0), coalesce(pendiente, 0),
       tiempo_fabricacion_dias,
       concat_ws(' | ',
         CASE WHEN estado_cliente = 'BLOQUEADO' THEN '⛔ CLIENTE BLOQUEADO' END,
         CASE WHEN estado_cliente = 'INACTIVO'  THEN 'Cliente inactivo' END,
         CASE WHEN vencido > 0 THEN 'Cartera vencida $' || to_char(vencido,'FM999G999G999') ||
                                    ' (' || dias_venc || ' días)' END,
         CASE WHEN precio_especial IS NOT NULL THEN 'Tiene precio especial vigente' END,
         CASE WHEN precio_lista IS NULL THEN 'Sin precio en lista' END,
         CASE WHEN coalesce(disponible,0) < 0
              THEN 'Inventario sobrecomprometido en ' || abs(disponible) || ' ' || unidad_medida END,
         CASE WHEN coalesce(disponible,0) <= 0 AND coalesce(en_produccion,0) > 0
              THEN 'Sin stock en almacén; hay ' || en_produccion || ' ' || unidad_medida || ' en producción' END,
         CASE WHEN coalesce(disponible,0) <= 0 AND coalesce(en_produccion,0) <= 0 AND tipo = 'FABRICADO'
              THEN 'Sin inventario: fabricación aprox. ' || coalesce(tiempo_fabricacion_dias::text,'¿?') || ' días' END,
         CASE WHEN coalesce(disponible,0) <= 0 AND coalesce(en_produccion,0) <= 0 AND tipo = 'DISTRIBUIDO'
              THEN 'Sin inventario: consultar a Compras (producto distribuido)' END,
         CASE WHEN dias_lote_mas_antiguo > qa.fn_parametro_int('dias_stock_antiguo')
              THEN 'Stock antiguo (' || dias_lote_mas_antiguo || ' días): oportunidad de promover' END,
         CASE WHEN fecha_ultima_compra IS NULL THEN 'Producto nuevo para el cliente' END)
FROM base
ORDER BY producto_id;
$$;
