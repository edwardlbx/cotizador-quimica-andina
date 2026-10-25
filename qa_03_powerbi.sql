/* =====================================================================
   QUÍMICA ANDINA S.A.S. (ficticia) — Script 03: vistas de apoyo para POWER BI
   Requiere qa_01_esquema.sql. Se puede ejecutar varias veces.
   ===================================================================== */
SET search_path TO qa, public;

-- Una fila por cliente y producto: todo lo necesario para cotizar.
-- En Power BI: segmentar por cliente y por producto.
CREATE OR REPLACE VIEW v_pbi_cotizacion AS
SELECT c.cliente_id,
       c.nombre                                          AS cliente,
       c.estado                                          AS estado_cliente,
       c.lista_precio,
       p.producto_id,
       p.producto_id || ' - ' || p.nombre                AS producto,
       p.tipo, p.familia, p.unidad_medida, p.venta_minima,
       CASE c.lista_precio WHEN 1 THEN pv.lista_1 WHEN 2 THEN pv.lista_2
                           WHEN 3 THEN pv.lista_3 WHEN 4 THEN pv.lista_4 END        AS precio_lista,
       pe.precio_especial,
       coalesce(pe.precio_especial,
                CASE c.lista_precio WHEN 1 THEN pv.lista_1 WHEN 2 THEN pv.lista_2
                                    WHEN 3 THEN pv.lista_3 WHEN 4 THEN pv.lista_4 END) AS precio_sugerido,
       CASE WHEN pe.precio_especial IS NOT NULL THEN 'ESPECIAL'
            ELSE 'LISTA ' || c.lista_precio END                                     AS origen_precio,
       uc.precio_ultima_compra,
       uc.fecha_ultima_compra,
       uc.cantidad_ultima_compra,
       coalesce(inv.disponible, 0)                       AS disponible,
       coalesce(inv.en_produccion, 0)                    AS en_produccion,
       inv.dias_lote_mas_antiguo,
       p.tiempo_fabricacion_dias,
       coalesce(ca.vencido_total, 0)                     AS cartera_vencida_cliente
FROM clientes c
CROSS JOIN productos p
LEFT JOIN v_precio_vigente pv           ON pv.producto_id = p.producto_id
LEFT JOIN v_precio_especial_vigente pe  ON pe.cliente_id = c.cliente_id AND pe.producto_id = p.producto_id
LEFT JOIN v_ultima_compra uc            ON uc.cliente_id = c.cliente_id AND uc.producto_id = p.producto_id
LEFT JOIN v_inventario_actual inv       ON inv.producto_id = p.producto_id
LEFT JOIN v_cartera_cliente ca          ON ca.cliente_id = c.cliente_id
WHERE p.estado = 'ACTIVO';

-- Ventas con nombres legibles (evita relaciones extra en Power BI)
CREATE OR REPLACE VIEW v_pbi_ventas AS
SELECT v.fecha,
       date_trunc('month', v.fecha)::date                AS mes,
       v.numero_factura, v.tipo,
       v.cliente_id, c.nombre                            AS cliente,
       v.vendedor_id, ve.nombre                          AS vendedor,
       v.producto_id, p.nombre                           AS producto,
       p.familia, p.tipo                                 AS tipo_producto,
       v.cantidad, v.valor_subtotal, v.precio_unitario,
       v.tipo_precio, v.dif_vs_lista_pct
FROM v_ventas v
JOIN clientes c          ON c.cliente_id  = v.cliente_id
JOIN productos p         ON p.producto_id = v.producto_id
LEFT JOIN vendedores ve  ON ve.vendedor_id = v.vendedor_id;
