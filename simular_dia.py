"""
Química Andina S.A.S. (ficticia) — Simulador de un DÍA DE OPERACIÓN
====================================================================
Lee el estado actual de la base y genera en `entrada/` los CSV que exportaría
un ERP genérico al final de un día: clientes, inventario, cartera, facturas, pedidos y
cotizaciones, con el mismo formato de generar_datos.py.

Qué pasa en el día simulado:
  - Un cliente nuevo, un cliente bloqueado por mora, otro desbloqueado tras pagar
    y uno que cambia de lista de precios.
  - Cotizaciones aprobadas que se convierten en pedidos; otras que se pierden;
    cotizaciones nuevas del día.
  - Despachos de pedidos abiertos (con su factura), un pedido anulado, pedidos nuevos.
  - Ventas de contado del día.
  - Inventario: baja por lo facturado, sube por lotes nuevos de producción.
  - Cartera: pagos totales y parciales, facturas nuevas a crédito.
Además deja `resumen_dia_<fecha>.txt` con lo que cambió, para verificarlo.

Uso (en la terminal, dentro de la carpeta del proyecto):
    python simular_dia.py                      # día = hoy, en Neon (toma la conexión de secrets.toml)
    python simular_dia.py --fecha 2026-10-24   # otro día
    python simular_dia.py --lab                # en qa_pruebas de este PC (laboratorio)
Después: .\\cargar.bat
"""
import argparse
import csv
import os
import random
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path

import psycopg2

p = argparse.ArgumentParser()
p.add_argument("--fecha", type=date.fromisoformat, default=date.today())
p.add_argument("--lab", action="store_true", help="usar qa_pruebas de este PC en vez de Neon")
p.add_argument("--base")
p.add_argument("--host")
p.add_argument("--puerto", type=int, default=5432)
p.add_argument("--usuario")
p.add_argument("--salida", default="entrada")
args = p.parse_args()

# Destino: Neon (lo que diga ~/.streamlit/secrets.toml, igual que el cotizador) o el laboratorio local
destino = {"host": "127.0.0.1", "dbname": "qa_pruebas", "user": "postgres", "sslmode": "prefer"}
secretos = Path.home() / ".streamlit" / "secrets.toml"
if not args.lab and secretos.exists():
    try:
        import tomllib                        # Python 3.11+
    except ImportError:
        import toml as tomllib                # viene con streamlit
    pg = tomllib.loads(secretos.read_text(encoding="utf-8")).get("postgres", {})
    destino = {"host": pg.get("host"), "dbname": pg.get("dbname"), "user": pg.get("user"),
               "password": pg.get("password"), "sslmode": pg.get("sslmode", "require")}
for k, v in (("host", args.host), ("dbname", args.base), ("user", args.usuario)):
    if v:
        destino[k] = v
args.base = destino["dbname"]

HOY = args.fecha
rnd = random.Random(int(HOY.strftime("%Y%m%d")))
OUT = Path(args.salida)
OUT.mkdir(exist_ok=True)
resumen = [f"DÍA SIMULADO: {HOY:%d/%m/%Y}  (base {args.base} en {destino['host']})", ""]


def q(sql, params=None):
    cur.execute(sql, params)
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


try:
    conn = psycopg2.connect(port=args.puerto, connect_timeout=10,
                            **{k: v for k, v in destino.items() if v},
                            **({"password": os.environ["PGPASSWORD"]}
                               if os.environ.get("PGPASSWORD") and "password" not in destino else {}))
except UnicodeDecodeError:
    raise SystemExit("No pude conectarme: revisa la contraseña ($env:PGPASSWORD) y el nombre de la base.")
cur = conn.cursor()


# ----------------------------------------------------------------------
# Formatos de exportación (iguales a generar_datos.py)
# ----------------------------------------------------------------------
def fmt_us(x, dec=0): return f"{x:,.{dec}f}"
def fmt_co(x): return "$" + f"{x:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
def fecha_mdy(d): return f"{d.month}/{d.day}/{d.year}"
def fecha_dmy(d): return d.strftime("%d/%m/%Y")
def nit_comas(n): return f"{int(n):,}"
def cod_txt(c): return c.lstrip("0") if (c.isdigit() and rnd.random() < 0.5) else c
def kg(x): return round(float(x), 2)

def escribir(nombre, encabezado, filas, delim=","):
    with open(OUT / nombre, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, delimiter=delim)
        w.writerow(encabezado)
        w.writerows(filas)
    print(f"  {nombre:<20} {len(filas):>6} filas")


# ----------------------------------------------------------------------
# Estado actual
# ----------------------------------------------------------------------
vendedores = {r["vendedor_id"]: r["nombre"] for r in q("SELECT vendedor_id, nombre FROM qa.vendedores")}
clientes = {r["cliente_id"]: r for r in q("SELECT * FROM qa.clientes")}
productos = {r["producto_id"]: r for r in q("SELECT * FROM qa.productos")}
precio = {}
for r in q("""SELECT DISTINCT ON (producto_id) producto_id, lista_1, lista_2, lista_3, lista_4
              FROM qa.precios WHERE vigente_desde <= %s ORDER BY producto_id, vigente_desde DESC""", (HOY,)):
    precio[r["producto_id"]] = [None, r["lista_1"], r["lista_2"], r["lista_3"], r["lista_4"]]

def precio_cli(cid, pid):
    return float(precio[pid][clientes[cid]["lista_precio"]])

corte_inv = q("SELECT max(fecha_corte) AS f FROM qa.inventario")[0]["f"]
inventario = q("SELECT * FROM qa.inventario WHERE fecha_corte = %s ORDER BY producto_id, bodega, lote", (corte_inv,))
corte_car = q("SELECT max(fecha_corte) AS f FROM qa.cartera")[0]["f"]
cartera = q("SELECT * FROM qa.cartera WHERE fecha_corte = %s", (corte_car,))
pedidos = {r["numero_pedido"]: r for r in q("SELECT * FROM qa.pedidos")}
ped_det = defaultdict(list)
for r in q("SELECT * FROM qa.pedidos_detalle ORDER BY numero_pedido, linea"):
    ped_det[r["numero_pedido"]].append(r)
cotiz = {r["numero_cotizacion"]: r for r in q("SELECT * FROM qa.cotizaciones")}
cot_det = defaultdict(list)
for r in q("SELECT * FROM qa.cotizaciones_detalle ORDER BY numero_cotizacion, linea"):
    cot_det[r["numero_cotizacion"]].append(r)
ventas_cli = defaultdict(list)
for r in q("""SELECT DISTINCT cliente_id, producto_id FROM qa.v_ventas
              WHERE tipo = 'FV' AND fecha >= %s - 365""", (HOY,)):
    ventas_cli[r["cliente_id"]].append(r["producto_id"])

def siguiente(prefijo, existentes, ancho):
    nums = [int(x.split("-")[-1]) for x in existentes if x.startswith(prefijo) and x.split("-")[-1].isdigit()]
    n = max(nums, default=0)
    while True:
        n += 1
        yield f"{prefijo}{n:0{ancho}d}"

facturas_db = [r["numero_factura"] for r in q("SELECT numero_factura FROM qa.facturas")]
nuevo_fe = siguiente("FE-", [x for x in facturas_db if len(x) == 11], 8)
nuevo_ped = siguiente("PED-", list(pedidos), 6)
nuevo_ctz = siguiente("CTZ-", list(cotiz), 8)

activos_prod = [pid for pid, x in productos.items() if x["estado"] == "ACTIVO" and pid in precio]
activos_cli = [c for c, x in clientes.items() if x["estado"] == "ACTIVO"]

# ----------------------------------------------------------------------
# 1. Clientes
# ----------------------------------------------------------------------
while True:
    nit_nuevo = str(rnd.randint(900_000_000, 901_999_999))
    if nit_nuevo not in clientes:
        break
# nombres genéricos: CLIENTE-0001, CLIENTE-0002...  (el nuevo toma el siguiente número)
numeros = [int(x["nombre"].split("-")[1][:4]) for x in clientes.values()
           if x["nombre"].startswith("CLIENTE-") and x["nombre"][8:12].isdigit()]
nombre_nuevo = f"CLIENTE-{max(numeros, default=0) + 1:04d}"
ciudad_nueva = rnd.choice(["Bogotá", "Medellín", "Cali", "Barranquilla", "Bucaramanga", "Pereira"])
clientes[nit_nuevo] = dict(cliente_id=nit_nuevo, nombre=nombre_nuevo, estado="ACTIVO",
                           ciudad=ciudad_nueva, segmento="EMPRESA", lista_precio=1, vendedor_id="V01",
                           condicion_pago_dias=30, cupo_credito=40_000_000)
activos_cli.append(nit_nuevo)
resumen.append(f"CLIENTE NUEVO: {clientes[nit_nuevo]['nombre']} (NIT {nit_nuevo}), lista 1, crédito 30 días")

saldo_cli = defaultdict(float)
mora_cli = defaultdict(int)
for r in cartera:
    saldo_cli[r["cliente_id"]] += float(r["saldo"])
    mora_cli[r["cliente_id"]] = max(mora_cli[r["cliente_id"]], (HOY - r["fecha_vencimiento"]).days)

morosos = sorted([c for c in activos_cli if mora_cli[c] > 60 and c != nit_nuevo], key=lambda c: -mora_cli[c])
if morosos:
    a_bloquear = morosos[0]
    clientes[a_bloquear]["estado"] = "BLOQUEADO"
    activos_cli.remove(a_bloquear)
    resumen.append(f"CLIENTE BLOQUEADO por mora de {mora_cli[a_bloquear]} días: {clientes[a_bloquear]['nombre']} "
                   f"(NIT {a_bloquear})")
bloqueados = [c for c, x in clientes.items() if x["estado"] == "BLOQUEADO" and c != (morosos[0] if morosos else None)]
desbloqueado = None
if bloqueados:
    desbloqueado = rnd.choice(bloqueados)
    clientes[desbloqueado]["estado"] = "ACTIVO"
    resumen.append(f"CLIENTE DESBLOQUEADO (pagó toda su cartera): {clientes[desbloqueado]['nombre']} "
                   f"(NIT {desbloqueado})")
cand_lista = [c for c in activos_cli if clientes[c]["lista_precio"] == 2 and c != nit_nuevo]
if cand_lista:
    sube = rnd.choice(cand_lista)
    clientes[sube]["lista_precio"] = 3
    resumen.append(f"CAMBIO DE LISTA 2 → 3: {clientes[sube]['nombre']} (NIT {sube})")

# reasignación de vendedor de un cliente que tiene un pedido abierto:
# el despacho de hoy debe quedar con el vendedor del PEDIDO, no con el nuevo
reasignado = None
con_pedido = sorted({x["cliente_id"] for x in pedidos.values()
                     if x["estado"] in ("ABIERTO", "PARCIAL") and x["cliente_id"] in activos_cli})
if con_pedido:
    reasignado = rnd.choice(con_pedido)
    antes = clientes[reasignado]["vendedor_id"]
    clientes[reasignado]["vendedor_id"] = rnd.choice([v for v in ("V01", "V02", "V03", "V04", "V05") if v != antes])
    resumen.append(f"CLIENTE REASIGNADO {antes} → {clientes[reasignado]['vendedor_id']}: "
                   f"{clientes[reasignado]['nombre']} (NIT {reasignado}). Sus pedidos abiertos conservan a {antes}.")

# ----------------------------------------------------------------------
# Inventario disponible (para despachar y facturar)
# ----------------------------------------------------------------------
inv = [dict(r) for r in inventario]
for r in inv:
    r["cantidad"] = float(r["cantidad"])
    r["cantidad_comprometida"] = 0.0

def disponible(pid):
    return sum(r["cantidad"] for r in inv if r["producto_id"] == pid and r["bodega"] == "VENTAS")

def sacar(pid, cantidad):
    """Descuenta del almacén (FIFO por lote) y devuelve el lote usado."""
    lote, resto = None, cantidad
    for r in sorted([r for r in inv if r["producto_id"] == pid and r["bodega"] == "VENTAS"],
                    key=lambda r: r["lote"] or ""):
        if resto <= 0:
            break
        usar = min(r["cantidad"], resto)
        if usar > 0:
            r["cantidad"] = round(r["cantidad"] - usar, 2)
            resto -= usar
            lote = lote or r["lote"]
    return lote or ""

facturas_hoy = []           # [numero, cliente, pid, cantidad, valor, lote, pedido]

def facturar(cid, items, pedido=""):
    num = next(nuevo_fe)
    for pid, cant, pu in items:
        facturas_hoy.append([num, cid, pid, kg(cant), round(cant * pu, 2), sacar(pid, cant), pedido])
    return num

# ----------------------------------------------------------------------
# 2. Cotizaciones → pedidos, perdidas y nuevas
# ----------------------------------------------------------------------
aprob = [c for c, x in cotiz.items() if x["estado_erp"] == "APROBADA"]
recientes = [c for c in aprob if (HOY - cotiz[c]["fecha"]).days <= 30 and cotiz[c]["cliente_id"] in activos_cli
             and cot_det[c]]
viejas = [c for c in aprob if 45 < (HOY - cotiz[c]["fecha"]).days <= 120]   # dentro de la ventana exportada
a_pedido = rnd.sample(recientes, min(3, len(recientes)))
nuevos_pedidos = []
for c in a_pedido:
    cotiz[c]["estado_erp"] = "PEDIDA"
    ped = next(nuevo_ped)
    cid = cotiz[c]["cliente_id"]
    pedidos[ped] = dict(numero_pedido=ped, cliente_id=cid, vendedor_id=cotiz[c]["vendedor_id"], fecha=HOY,
                        estado="ABIERTO")
    ped_det[ped] = [dict(producto_id=d["producto_id"], cantidad_pedida=float(d["cantidad"]),
                         cantidad_despachada=0.0, precio_unitario=float(d["precio_unitario"])) for d in cot_det[c]]
    nuevos_pedidos.append(ped)
    resumen.append(f"COTIZACIÓN {c} → PEDIDA: se creó el pedido {ped} ({clientes[cid]['nombre']})")
for c in rnd.sample(viejas, min(4, len(viejas))):
    cotiz[c]["estado_erp"] = "PERDIDA"
    resumen.append(f"COTIZACIÓN {c} → PERDIDA ({clientes[cotiz[c]['cliente_id']]['nombre']})")

nuevas_ctz = []
for i, cid in enumerate([nit_nuevo] + rnd.sample(activos_cli, 4)):
    ctz = next(nuevo_ctz)
    prods = ventas_cli.get(cid) or rnd.sample(activos_prod, 2)
    prods = [x for x in prods if x in precio][:3] or rnd.sample(activos_prod, 2)
    estado = "EN_ELABORACION" if i >= 3 else "APROBADA"
    cotiz[ctz] = dict(numero_cotizacion=ctz, centro_operacion="001", cliente_id=cid,
                      vendedor_id=clientes[cid]["vendedor_id"], fecha=HOY, estado_erp=estado)
    cot_det[ctz] = [dict(producto_id=x, cantidad=float(max(productos[x]["venta_minima"] or 1, rnd.choice([5, 10, 20, 25]))),
                         precio_unitario=precio_cli(cid, x)) for x in rnd.sample(prods, min(len(prods), rnd.randint(1, 3)))]
    nuevas_ctz.append(ctz)
resumen.append(f"COTIZACIONES NUEVAS del día: {', '.join(nuevas_ctz)} (incluye una del cliente nuevo)")

# ----------------------------------------------------------------------
# 3. Pedidos: despachos (con factura), anulación y pedido nuevo directo
# ----------------------------------------------------------------------
abiertos = [p_ for p_, x in pedidos.items() if x["estado"] in ("ABIERTO", "PARCIAL") and p_ not in nuevos_pedidos]
rnd.shuffle(abiertos)
abiertos.sort(key=lambda p_: pedidos[p_]["cliente_id"] != reasignado)   # su pedido se despacha hoy (para verlo)
if abiertos:
    anulado = abiertos.pop()
    if pedidos[anulado]["cliente_id"] == reasignado and len(abiertos) > 1:
        abiertos.insert(0, anulado)
        anulado = abiertos.pop()
    pedidos[anulado]["estado"] = "ANULADO"
    resumen.append(f"PEDIDO ANULADO: {anulado} ({clientes[pedidos[anulado]['cliente_id']]['nombre']})")
for ped in abiertos[:6]:
    cid = pedidos[ped]["cliente_id"]
    if clientes[cid]["estado"] == "BLOQUEADO":
        continue
    items = []
    for d in ped_det[ped]:
        pend = float(d["cantidad_pedida"]) - float(d["cantidad_despachada"])
        enviar = round(min(pend, disponible(d["producto_id"])), 2)
        if enviar > 0:
            items.append((d["producto_id"], enviar, float(d["precio_unitario"] or precio_cli(cid, d["producto_id"]))))
            d["cantidad_despachada"] = round(float(d["cantidad_despachada"]) + enviar, 2)
    if not items:
        continue
    total = all(float(d["cantidad_despachada"]) >= float(d["cantidad_pedida"]) for d in ped_det[ped])
    pedidos[ped]["estado"] = "CERRADO" if total else "PARCIAL"
    fe = facturar(cid, items, ped)
    resumen.append(f"DESPACHO pedido {ped} → {pedidos[ped]['estado']}, facturado en {fe} "
                   f"({clientes[cid]['nombre']})")

ped = next(nuevo_ped)
pids = rnd.sample(activos_prod, 2)
pedidos[ped] = dict(numero_pedido=ped, cliente_id=nit_nuevo, vendedor_id="V01", fecha=HOY, estado="ABIERTO")
ped_det[ped] = [dict(producto_id=x, cantidad_pedida=25.0, cantidad_despachada=0.0, precio_unitario=precio_cli(nit_nuevo, x))
                for x in pids]
resumen.append(f"PEDIDO NUEVO del cliente nuevo: {ped} ({', '.join(pids)})")

# ventas de contado (emprendedores)
contado = [c for c in activos_cli if clientes[c]["condicion_pago_dias"] == 0 and ventas_cli.get(c)]
for cid in rnd.sample(contado, min(2, len(contado))):
    items = []
    for pid in rnd.sample(ventas_cli[cid], min(2, len(ventas_cli[cid]))):
        if pid in precio and disponible(pid) >= 2:
            items.append((pid, float(rnd.choice([1, 2, 3, 5])), precio_cli(cid, pid)))
    if items:
        fe = facturar(cid, items)
        resumen.append(f"VENTA DE CONTADO {fe}: {clientes[cid]['nombre']}")

# nota crédito por devolución parcial de una factura reciente (la factura original NO cambia)
ncs_hoy = []                # [numero, cliente, pid, cantidad(-), valor(-), lote, factura_ref]
recientes_fv = q("""SELECT f.numero_factura, f.cliente_id, f.vendedor_id, d.producto_id, d.cantidad, d.precio_unitario, d.lote
                     FROM qa.facturas f JOIN qa.facturas_detalle d USING (numero_factura)
                     WHERE f.tipo = 'FV' AND f.fecha BETWEEN %s - 30 AND %s - 3 AND d.cantidad >= 2
                     ORDER BY f.numero_factura, d.linea""", (HOY, HOY))
if recientes_fv:
    nuevo_nc = siguiente("NC-", [x for x in facturas_db if x.startswith("NC-")], 8)
    r = rnd.choice(recientes_fv)
    cant = -round(float(r["cantidad"]) * 0.2, 2)
    ncs_hoy.append([next(nuevo_nc), r["cliente_id"], r["producto_id"], cant,
                    round(cant * float(r["precio_unitario"]), 2), r["lote"] or "", r["numero_factura"]])
    nc_vend = {ncs_hoy[0][0]: r["vendedor_id"]}      # la NC va al vendedor de la factura que corrige
    resumen.append(f"NOTA CRÉDITO {ncs_hoy[0][0]} por devolución del 20 % de {r['producto_id']} "
                   f"en {r['numero_factura']} ({clientes[r['cliente_id']]['nombre']}). La factura no se modifica.")

# ----------------------------------------------------------------------
# 4. Inventario: producción terminada y comprometido
# ----------------------------------------------------------------------
fabricados = [pid for pid in activos_prod if productos[pid]["tipo"] == "FABRICADO"]
for pid in rnd.sample(fabricados, 5):
    cant = float(rnd.choice([20, 40, 60, 100, 150]))
    inv.append(dict(producto_id=pid, bodega="VENTAS", lote=f"{HOY:%Y%m%d}{rnd.randint(1, 9):03d}",
                    ubicacion=f"{rnd.choice('ABCFG')}{rnd.randint(1, 19)}", presentacion="25 KG",
                    cantidad=cant, cantidad_comprometida=0.0))
    for r in inv:
        if r["producto_id"] == pid and r["bodega"] == "PRODUCCION":
            r["cantidad"] = 0.0
    resumen.append(f"PRODUCCIÓN TERMINADA: {pid} +{cant:.0f} kg al almacén (VENTAS)")
pendiente = defaultdict(float)
for ped_, x in pedidos.items():
    if x["estado"] in ("ABIERTO", "PARCIAL"):
        for d in ped_det[ped_]:
            pendiente[d["producto_id"]] += float(d["cantidad_pedida"]) - float(d["cantidad_despachada"])
for pid, pend in pendiente.items():
    filas = [r for r in inv if r["producto_id"] == pid and r["bodega"] == "VENTAS"]
    if not filas:
        filas = [dict(producto_id=pid, bodega="VENTAS", lote="", ubicacion="", presentacion="KG",
                      cantidad=0.0, cantidad_comprometida=0.0)]
        inv.append(filas[0])
    filas[0]["cantidad_comprometida"] = round(pend, 2)

# ----------------------------------------------------------------------
# 5. Cartera: pagos y facturas nuevas a crédito
# ----------------------------------------------------------------------
car = [dict(r) for r in cartera]
pagadas = [r for r in car if r["cliente_id"] == desbloqueado]
otros = [r for r in car if r["cliente_id"] != desbloqueado and mora_cli[r["cliente_id"]] <= 60]
pagadas += rnd.sample(otros, min(6, len(otros)))
for r in pagadas:
    r["saldo"] = 0
resumen.append(f"PAGOS TOTALES: {len(pagadas)} facturas salen de cartera")
for r in rnd.sample([r for r in car if float(r["saldo"]) > 0], 2):
    r["saldo"] = round(float(r["saldo"]) * 0.5, -2)
    resumen.append(f"ABONO del 50 % a {r['numero_documento']} ({clientes[r['cliente_id']]['nombre']})")
for nc in ncs_hoy:                     # la NC descuenta del saldo de su factura
    for r in car:
        if r["numero_documento"] == nc[6]:
            r["saldo"] = max(0.0, round(float(r["saldo"]) + nc[4], 2))
car = [r for r in car if float(r["saldo"]) > 0]
por_fe = defaultdict(float)
cli_fe = {}
for num, cid, pid, cant, valor, lote, pedido in facturas_hoy:
    por_fe[num] += valor
    cli_fe[num] = cid
for num, valor in por_fe.items():
    cid = cli_fe[num]
    dias = clientes[cid]["condicion_pago_dias"] or 0
    if dias > 0:
        car.append(dict(numero_documento=num, cliente_id=cid, vendedor_id=clientes[cid]["vendedor_id"],
                        fecha_emision=HOY, fecha_vencimiento=HOY + timedelta(days=dias), saldo=valor))

# ----------------------------------------------------------------------
# 6. Escribir los CSV (mismo formato que generar_datos.py)
# ----------------------------------------------------------------------
print(f"\nArchivos del {HOY:%d/%m/%Y} en '{OUT}/':")
escribir("clientes.csv",
         ["NIT", "Razon social", "Ciudad", "Segmento", "Estado", "Lista precios", "Vendedor",
          "Condicion pago (dias)", "Cupo credito"],
         [[nit_comas(c["cliente_id"]), c["nombre"], c["ciudad"], c["segmento"], c["estado"], c["lista_precio"],
           c["vendedor_id"], c["condicion_pago_dias"], fmt_us(float(c["cupo_credito"] or 0))]
          for c in clientes.values()])

escribir("inventario.csv", ["Referencia", "Descripcion", "Bodega", "Lote", "Ubicacion", "Presentacion",
                            "Cantidad", "Comprometido"],
         [[cod_txt(r["producto_id"]), productos[r["producto_id"]]["nombre"], r["bodega"], r["lote"] or "",
           r["ubicacion"] or "", r["presentacion"] or "", f"{max(r['cantidad'], 0):.2f}",
           f"{r['cantidad_comprometida']:.2f}"] for r in inv])

escribir("cartera.csv", ["Documento", "Cliente", "Vendedor", "NIT cliente",
                         "Fecha documento", "Fecha vencimiento", "Dias vencidos", "Saldo"],
         [[r["numero_documento"], clientes[r["cliente_id"]]["nombre"],
           vendedores.get(r["vendedor_id"] or clientes[r["cliente_id"]]["vendedor_id"], ""),
           nit_comas(r["cliente_id"]), fecha_mdy(r["fecha_emision"]), fecha_mdy(r["fecha_vencimiento"]),
           (HOY - r["fecha_vencimiento"]).days, fmt_us(float(r["saldo"]))] for r in car])

# facturas: últimos 90 días (lo ya cargado se actualiza sin duplicar) + las de hoy
filas = []
for r in q("""SELECT f.fecha, f.cliente_id, f.numero_factura, d.producto_id, p.nombre, d.cantidad,
                     d.valor_subtotal, d.lote, f.numero_pedido, f.vendedor_id, f.fecha_vencimiento,
                     to_jsonb(f) ->> 'factura_referencia' AS factura_referencia
              FROM qa.facturas f JOIN qa.facturas_detalle d USING (numero_factura)
              JOIN qa.productos p USING (producto_id)
              WHERE f.fecha >= %s - 90 ORDER BY f.fecha, f.numero_factura, d.linea""", (HOY,)):
    filas.append([fecha_mdy(r["fecha"]), r["cliente_id"], r["numero_factura"],
                  f"{cod_txt(r['producto_id'])} {r['nombre']}", f"{float(r['cantidad']):.2f}",
                  f"{float(r['valor_subtotal']):.2f}", r["lote"] or "", r["numero_pedido"] or "",
                  r["vendedor_id"] or "", fecha_mdy(r["fecha_vencimiento"] or r["fecha"]),
                  r["factura_referencia"] or ""])
for num, cid, pid, cant, valor, lote, pedido in facturas_hoy:
    vend = pedidos[pedido]["vendedor_id"] if pedido else clientes[cid]["vendedor_id"]
    vcto = HOY + timedelta(days=clientes[cid]["condicion_pago_dias"] or 0)
    filas.append([fecha_mdy(HOY), cid, num, f"{cod_txt(pid)} {productos[pid]['nombre']}", f"{cant:.2f}",
                  f"{valor:.2f}", lote, pedido, vend or "", fecha_mdy(vcto), ""])
for num, cid, pid, cant, valor, lote, ref in ncs_hoy:
    filas.append([fecha_mdy(HOY), cid, num, f"{cod_txt(pid)} {productos[pid]['nombre']}", f"{cant:.2f}",
                  f"{valor:.2f}", lote, "", nc_vend.get(num) or "", fecha_mdy(HOY), ref])
escribir("facturas.csv", ["Fecha", "NIT cliente", "Documento", "Producto", "Cantidad",
                          "Valor subtotal", "Lote", "Pedido", "Vendedor", "Fecha vencimiento",
                          "Factura referencia"], filas)
resumen.append(f"FACTURAS NUEVAS del día: {len(por_fe)} "
               f"({', '.join(sorted(por_fe))}) por {fmt_us(sum(por_fe.values()))}")

# pedidos: últimos 120 días + todos los abiertos
EST = {"ABIERTO": "Abierto", "PARCIAL": "Parcial", "CERRADO": "Cerrado", "ANULADO": "Anulado"}
filas = []
for ped_, x in sorted(pedidos.items()):
    if (HOY - x["fecha"]).days > 120 and x["estado"] not in ("ABIERTO", "PARCIAL"):
        continue
    for d in ped_det[ped_]:
        filas.append([ped_, fecha_dmy(x["fecha"]), nit_comas(x["cliente_id"]), x["vendedor_id"] or "",
                      cod_txt(d["producto_id"]), f"{float(d['cantidad_pedida']):.2f}",
                      f"{float(d['cantidad_despachada']):.2f}", f"{float(d['precio_unitario'] or 0):.2f}",
                      EST[x["estado"]]])
escribir("pedidos.csv", ["Pedido", "Fecha", "NIT cliente", "Vendedor", "Referencia", "Cant. pedida",
                         "Cant. despachada", "Precio unitario", "Estado"], filas)

# cotizaciones: últimos 120 días (separador ';', fechas d/m/a, $1.062.000,00)
ESTC = {"EN_ELABORACION": "En elaboración", "APROBADA": "Aprobadas", "PEDIDA": "Pedidas", "PERDIDA": "Perdidas"}
filas = []
for c, x in sorted(cotiz.items()):
    if (HOY - x["fecha"]).days > 120:
        continue
    for d in cot_det[c]:
        cant, pu = float(d["cantidad"]), float(d["precio_unitario"])
        filas.append([x["centro_operacion"] or "001", c, fecha_dmy(x["fecha"]), ESTC[x["estado_erp"]],
                      nit_comas(x["cliente_id"]), x["vendedor_id"] or "", cod_txt(d["producto_id"]),
                      f"{cant:g}".replace(".", ","), fmt_co(pu), fmt_co(cant * pu)])
escribir("cotizaciones.csv", ["Sede", "Cotizacion", "Fecha", "Estado", "NIT cliente", "Vendedor",
                              "Referencia", "Cantidad", "Precio unitario", "Valor subtotal"], filas, delim=";")

with open(OUT.parent / f"resumen_dia_{HOY:%Y-%m-%d}.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(resumen) + "\n")
print("\n" + "\n".join(resumen))
conn.close()
