"""
Química Andina S.A.S. (empresa ficticia) — Generador de datos sintéticos
=======================================================================
Crea en la carpeta `entrada/` los CSV que exportaría un ERP genérico, con los
problemas típicos de una exportación real (números con separadores, fechas d/m/a
y m/d/a, NIT con comas, códigos sin ceros, código y nombre en una sola columna, etc.) y con patrones útiles para el
pronóstico: segmentación ABC, estacionalidad, crecimiento, compras atípicas,
productos nuevos y clientes morosos. También siembra algunos errores para
probar la validación del kit de carga.

Uso:
    python generar_datos.py                 # datos hasta hoy
    python generar_datos.py --hasta 2026-10-21 --semilla 42

Todos los datos son ficticios.
"""
import argparse
import csv
import random
from datetime import date, timedelta
from pathlib import Path

import numpy as np

# ----------------------------------------------------------------------
# Parámetros
# ----------------------------------------------------------------------
N_PRODUCTOS = 300
N_CLIENTES = 150
INICIO = date(2023, 10, 1)

p = argparse.ArgumentParser()
p.add_argument("--hasta", type=date.fromisoformat, default=date.today())
p.add_argument("--semilla", type=int, default=42)
p.add_argument("--salida", default="entrada")
args = p.parse_args()

HOY = args.hasta
rng = np.random.default_rng(args.semilla)
random.seed(args.semilla)
OUT = Path(args.salida)
OUT.mkdir(exist_ok=True)


# ----------------------------------------------------------------------
# Formatos de exportación
# ----------------------------------------------------------------------
def fmt_us(x, dec=0):                      # 2,135,455   (estilo inglés)
    return f"{x:,.{dec}f}"

def fmt_co(x):                             # $1.062.000,00 (estilo es-CO)
    s = f"{x:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
    return "$" + s

def fecha_mdy(d):                          # 10/9/2026 = 9 de octubre
    return f"{d.month}/{d.day}/{d.year}"

def fecha_dmy(d):                          # 09/10/2026 = 9 de octubre
    return d.strftime("%d/%m/%Y")

def nit_comas(n):                          # 901802759 -> 901,802,759
    return f"{int(n):,}"

def escribir(nombre, encabezado, filas, delim=","):
    with open(OUT / nombre, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, delimiter=delim, quoting=csv.QUOTE_MINIMAL)
        w.writerow(encabezado)
        w.writerows(filas)
    print(f"  {nombre:<26} {len(filas):>7,} filas".replace(",", "."))

def meses_entre(a, b):
    m, out = date(a.year, a.month, 1), []
    while m <= b:
        out.append(m)
        m = date(m.year + (m.month // 12), m.month % 12 + 1, 1)
    return out


# ----------------------------------------------------------------------
# 1. Vendedores
# ----------------------------------------------------------------------
vendedores = [
    ("V01", "MORALES RUIZ CAMILA ANDREA", "Valle"),
    ("V02", "OSPINA TORRES JULIAN DAVID", "Antioquia"),
    ("V03", "CARDENAS LOPEZ MARIA FERNANDA", "Bogotá"),
    ("V04", "RIVAS MEJIA SANTIAGO", "Eje Cafetero"),
    ("V05", "GUTIERREZ PAEZ LAURA VALENTINA", "Costa"),
    ("V06", "QUIMICA ANDINA (CASA)", None),
]
VEND_IDS = [v[0] for v in vendedores[:-1]]


# ----------------------------------------------------------------------
# 2. Productos
# ----------------------------------------------------------------------
# Catálogo genérico: el nombre es PRODUCTO-<código>. Tres líneas de producto:
#   A = fabricados de volumen medio · B = distribuidos (alto volumen, precio bajo) · C = fabricados de alto valor
nombres = ([("A", "Línea A", "FABRICADO")] * 225 + [("B", "Línea B", "DISTRIBUIDO")] * 43
           + [("C", "Línea C", "FABRICADO")] * 32)
random.shuffle(nombres)
nombres = nombres[:N_PRODUCTOS - 10]          # 10 cupos para variantes "E"

codigos = sorted(random.sample(range(1, 5000), len(nombres)))
productos = []                                 # dicts
for cod, (fam, cat, tipo) in zip(codigos, nombres):
    lanzamiento = INICIO - timedelta(days=int(rng.integers(200, 2000)))
    if rng.random() < 0.08:                    # ~8 % lanzados en 2025-2026
        lanzamiento = date(2025, 1, 1) + timedelta(days=int(rng.integers(0, (HOY - date(2025, 1, 1)).days - 60)))
    productos.append(dict(
        codigo=str(cod), nombre=f"PRODUCTO-{cod:04d}", familia=fam, categoria=cat, tipo=tipo,
        unidad="KG", base=None, lanzamiento=lanzamiento,
        venta_min=random.choice([0.25, 0.5, 1, 1, 1, 1, 3, 5, 25] if fam != "B" else [1, 1, 5, 25, 25]),
        estado="DESCONTINUADO" if rng.random() < 0.03 else "ACTIVO"))
# variantes "E" de algunos fabricados
for base in random.sample([x for x in productos if x["familia"] in ("A", "C")], 10):
    productos.append({**base, "codigo": base["codigo"] + "E", "nombre": base["nombre"] + "E",
                      "base": base["codigo"]})

# popularidad tipo Pareto (pocos productos concentran las ventas)
pop = rng.pareto(1.3, len(productos)) + 0.05
pop = pop / pop.sum()
for prod, w in zip(productos, pop):
    prod["pop"] = w
    prod["kg_mes"] = {"B": 160, "A": 25, "C": 10}[prod["familia"]] * (0.3 + 25 * w)
    base_precio = {"B": rng.uniform(6_000, 60_000), "A": rng.uniform(25_000, 220_000),
                   "C": rng.uniform(60_000, 260_000)}[prod["familia"]]
    prod["precio_2026"] = round(base_precio, -2)
    if prod["codigo"].endswith("E"):
        prod["kg_mes"] *= 0.4

def cod_txt(c):
    """En el CSV unos códigos salen con ceros ('0007') y otros sin ellos ('7')."""
    return c.zfill(4) if (c.isdigit() and rng.random() < 0.5) else c

escribir("productos.csv",
         ["Referencia", "Descripcion", "Tipo", "Linea", "U.M.", "Venta minima", "Estado"],
         [[cod_txt(x["codigo"]), x["nombre"],
           "PRODUCTO FABRICADO" if x["tipo"] == "FABRICADO" else "COMERCIALIZADO",
           x["categoria"], x["unidad"], str(x["venta_min"]).replace(".", ","), x["estado"]]
          for x in productos])

escribir("tiempos_fabricacion.csv", ["Referencia", "Dias fabricacion"],
         [[x["codigo"], int(rng.choice([5, 7, 8, 10, 12, 15, 20]))]
          for x in productos if x["tipo"] == "FABRICADO"])


# ----------------------------------------------------------------------
# 3. Precios (histórico anual de listas)
# ----------------------------------------------------------------------
fechas_lista = [date(2023, 1, 15), date(2024, 1, 15), date(2025, 1, 15), date(2026, 1, 15)]
factor_anual = {date(2023, 1, 15): 0.81, date(2024, 1, 15): 0.87, date(2025, 1, 15): 0.93, date(2026, 1, 15): 1.0}
desc_lista = {1: 1.0, 2: 0.95, 3: 0.90, 4: 0.84}

def precio_lista(prod, lista, d):
    vig = max([f for f in fechas_lista if f <= d], default=fechas_lista[0])
    return round(prod["precio_2026"] * factor_anual[vig] * desc_lista[lista], -2)

filas = []
for f in fechas_lista:
    for x in productos:
        if x["lanzamiento"] > f + timedelta(days=330):
            continue
        filas.append([cod_txt(x["codigo"]), x["nombre"]] +
                     [fmt_us(precio_lista(x, l, f)) for l in (1, 2, 3, 4)] +
                     [f"{x['venta_min']} {x['unidad']}".replace(".", ","),
                      random.choice(["", "", "", "", "Promocionar stock", "Grado especial"]),
                      fecha_dmy(f)])
escribir("precios.csv", ["Refer", "Nombre", "Lista 01", "Lista 02", "Lista 03", "Lista 04",
                         "Venta minima", "Comentarios", "Vigente desde"], filas)


# ----------------------------------------------------------------------
# 4. Clientes
# ----------------------------------------------------------------------
ciudades = ["Bogotá", "Bogotá", "Bogotá", "Medellín", "Medellín", "Cali", "Cali", "Barranquilla",
            "Bucaramanga", "Pereira", "Cartagena", "Manizales"]

clientes = []
for i in range(N_CLIENTES):
    nom = f"CLIENTE-{i + 1:04d}"                 # nombre genérico
    if rng.random() < 0.7:
        nit, seg = int(rng.integers(800_000_000, 901_999_999)), "EMPRESA"
    else:
        nit, seg = int(rng.integers(10_000_000, 1_150_000_000)), "EMPRENDEDOR"
    perfil = rng.choice(["frecuente", "regular", "ocasional"], p=[0.25, 0.4, 0.35])
    tamano = {"EMPRESA": rng.lognormal(0.6, 0.7), "EMPRENDEDOR": rng.lognormal(-1.2, 0.5)}[seg]
    lista = 1 if seg == "EMPRENDEDOR" else int(rng.choice([1, 2, 3, 4], p=[0.2, 0.3, 0.3, 0.2]))
    clientes.append(dict(
        nit=nit, nombre=nom, seg=seg, ciudad=random.choice(ciudades), lista=lista,
        vendedor=random.choice(VEND_IDS), perfil=perfil, tamano=tamano,
        dias=0 if seg == "EMPRENDEDOR" else int(rng.choice([30, 30, 45, 60])),
        cupo=0 if seg == "EMPRENDEDOR" else round(float(rng.uniform(20, 200)) * 1e6, -6),
        alta=INICIO - timedelta(days=int(rng.integers(30, 1500))) if rng.random() < 0.85
             else INICIO + timedelta(days=int(rng.integers(0, (HOY - INICIO).days - 90))),
        moroso=rng.random() < 0.12,
        estado="ACTIVO"))
for c in random.sample(clientes, 8):
    c["estado"] = "INACTIVO"
for c in random.sample([c for c in clientes if c["moroso"] and c["seg"] == "EMPRESA"], 4):
    c["estado"] = "BLOQUEADO"

escribir("clientes.csv",
         ["NIT", "Razon social", "Ciudad", "Segmento", "Estado", "Lista precios", "Vendedor",
          "Condicion pago (dias)", "Cupo credito"],
         [[nit_comas(c["nit"]), c["nombre"], c["ciudad"], c["seg"], c["estado"], c["lista"],
           c["vendedor"], c["dias"], fmt_us(c["cupo"])] for c in clientes])
escribir("vendedores.csv", ["Codigo", "Nombre", "Zona"], [list(v) for v in vendedores])


# ----------------------------------------------------------------------
# 5. Facturas (ventas) con estacionalidad, crecimiento y atípicos
# ----------------------------------------------------------------------
activos = [x for x in productos if x["estado"] == "ACTIVO" or rng.random() < 0.5]
for c in clientes:
    k = int(rng.integers(4, 18)) if c["seg"] == "EMPRESA" else int(rng.integers(2, 7))
    w = np.array([x["pop"] for x in activos])
    c["canasta"] = list(rng.choice(len(activos), size=k, replace=False, p=w / w.sum()))

prob_mes = {"frecuente": 0.85, "regular": 0.5, "ocasional": 0.18}

def estacional(m):
    return 1 + 0.30 * np.cos(2 * np.pi * (m - 11) / 12) + 0.12 * np.cos(2 * np.pi * (m - 5) / 6)

facturas, n_fe, n_nc = [], 33000, 1200
for mes in meses_entre(INICIO, HOY):
    crecimiento = 1.10 ** ((mes - INICIO).days / 365.25)
    for c in clientes:
        if mes < date(c["alta"].year, c["alta"].month, 1) or (c["estado"] == "INACTIVO" and mes > HOY - timedelta(days=200)):
            continue
        if rng.random() > prob_mes[c["perfil"]]:
            continue
        dia = int(rng.integers(1, 28))
        f = date(mes.year, mes.month, dia)
        if f > HOY:
            continue
        n_fe += 1
        num = f"FE-{n_fe:08d}"
        items = rng.choice(c["canasta"], size=min(len(c["canasta"]), int(rng.integers(1, 5))), replace=False)
        for idx in items:
            x = activos[idx]
            if x["lanzamiento"] > f:
                continue
            kg = x["kg_mes"] * c["tamano"] * estacional(f.month) * crecimiento * rng.uniform(0.5, 1.5) / 6
            kg = max(x["venta_min"], round(kg, 2) if kg < 5 else round(kg))
            pl = precio_lista(x, c["lista"], f)
            precio = pl if rng.random() < 0.8 else round(pl * rng.uniform(0.92, 0.98), -2)
            lote = f"{(f - timedelta(days=int(rng.integers(5, 60)))):%Y%m%d}{int(rng.integers(1, 9)):03d}"
            facturas.append([f, c["nit"], num, x["codigo"], x["nombre"], kg, kg * precio, lote])

# compras atípicas (las que distorsionan el promedio)
for _ in range(8):
    c = random.choice([c for c in clientes if c["seg"] == "EMPRESA"])
    x = activos[random.choice(c["canasta"])]
    f = INICIO + timedelta(days=int(rng.integers(60, (HOY - INICIO).days - 10)))
    if x["lanzamiento"] > f: continue
    n_fe += 1
    kg = round(max(x["kg_mes"] * c["tamano"] / 6, x["venta_min"]) * rng.uniform(15, 25))
    facturas.append([f, c["nit"], f"FE-{n_fe:08d}", x["codigo"], x["nombre"], kg,
                     kg * precio_lista(x, c["lista"], f), f"{f:%Y%m%d}009"])

# notas crédito (devoluciones)
for row in random.sample(facturas, 25):
    n_nc += 1
    kg = -round(abs(row[5]) * rng.uniform(0.1, 0.5), 2)
    facturas.append([row[0] + timedelta(days=int(rng.integers(3, 20))), row[1], f"NC-{n_nc:08d}",
                     row[3], row[4], kg, row[6] / row[5] * kg, row[7], row[2]])   # último = factura que corrige
facturas = [r for r in facturas if r[0] <= HOY]
facturas.sort(key=lambda r: (r[0], r[2]))

# pedidos de los últimos 120 días enlazados a sus facturas
corte_ped = HOY - timedelta(days=120)
ped_de_factura, n_ped = {}, 7000
for r in facturas:
    if r[0] >= corte_ped and r[2].startswith("FE") and r[2] not in ped_de_factura:
        n_ped += 1
        ped_de_factura[r[2]] = f"PED-{n_ped:06d}"

filas = []
cli_nit = {c["nit"]: c for c in clientes}
for r in facturas:
    f, nit, num, cod, nom, kg, val, lote = r[:8]
    ref = r[8] if len(r) > 8 else ""
    vcto = f if num.startswith("NC") else f + timedelta(days=cli_nit[nit]["dias"])
    filas.append([fecha_mdy(f), f"{nit}", num, f"{cod_txt(cod)} {nom}",
                  f"{kg:.2f}", f"{val:.2f}", lote, ped_de_factura.get(num, ""),
                  cli_nit[nit]["vendedor"], fecha_mdy(vcto), ref])
# errores sembrados: fechas vacías, cliente y producto inexistentes
for i in random.sample(range(len(filas)), max(3, len(filas) // 120)):
    filas[i][0] = ""
filas.append([fecha_mdy(HOY - timedelta(days=3)), "999999999", "FE-99999901", "0053 ACIDO LACTICO", "10.00", "260000.00", "L4661431", "", "V01", fecha_mdy(HOY + timedelta(days=27)), ""])
filas.append([fecha_mdy(HOY - timedelta(days=2)), str(clientes[0]["nit"]), "FE-99999902", "9999 PRODUCTO DESCONOCIDO", "5.00", "100000.00", "", "", "V01", fecha_mdy(HOY + timedelta(days=28)), ""])
escribir("facturas.csv", ["Fecha", "NIT cliente", "Documento", "Producto", "Cantidad",
                          "Valor subtotal", "Lote", "Pedido", "Vendedor", "Fecha vencimiento",
                          "Factura referencia"], filas)


# ----------------------------------------------------------------------
# 6. Pedidos: cerrados (ya facturados) + abiertos/parciales
# ----------------------------------------------------------------------
nit_cli = {c["nit"]: c for c in clientes}
prod_cod = {x["codigo"]: x for x in productos}
pedidos = []
for r in facturas:
    if r[2] in ped_de_factura:
        c = nit_cli[r[1]]
        pedidos.append([ped_de_factura[r[2]], r[0] - timedelta(days=int(rng.integers(1, 6))), r[1],
                        c["vendedor"], r[3], r[5], r[5], r[6] / r[5], "Cerrado"])
comprometido = {}
for _ in range(30):
    c = random.choice([c for c in clientes if c["estado"] == "ACTIVO"])
    n_ped += 1
    f = HOY - timedelta(days=int(rng.integers(0, 20)))
    estado = random.choice(["Abierto", "Abierto", "Parcial"])
    for idx in rng.choice(c["canasta"], size=min(2, len(c["canasta"])), replace=False):
        x = activos[idx]
        kg = max(x["venta_min"], round(x["kg_mes"] * c["tamano"] * rng.uniform(0.3, 1.0) / 6))
        desp = round(kg * rng.uniform(0.3, 0.7)) if estado == "Parcial" else 0
        comprometido[x["codigo"]] = comprometido.get(x["codigo"], 0) + (kg - desp)
        pedidos.append([f"PED-{n_ped:06d}", f, c["nit"], c["vendedor"], x["codigo"], kg, desp,
                        precio_lista(x, c["lista"], f), estado])
escribir("pedidos.csv", ["Pedido", "Fecha", "NIT cliente", "Vendedor", "Referencia",
                         "Cant. pedida", "Cant. despachada", "Precio unitario", "Estado"],
         [[p[0], fecha_dmy(p[1]), nit_comas(p[2]), p[3], cod_txt(p[4]), f"{p[5]:.2f}", f"{p[6]:.2f}",
           f"{p[7]:.2f}", p[8]] for p in pedidos])


# ----------------------------------------------------------------------
# 7. Inventario (foto de hoy)
# ----------------------------------------------------------------------
filas = []
ubic = [f"{l}{n}" for l in "ABCFG" for n in range(1, 20)]
for x in productos:
    if x["estado"] != "ACTIVO":
        continue
    pres = random.choice(["1 KG", "2 KG", "5 KG", "20 KG", "25 KG"])
    n_lotes = int(rng.choice([0, 1, 1, 2, 3], p=[0.12, 0.4, 0.2, 0.18, 0.1]))
    total = x["kg_mes"] * rng.uniform(0.2, 2.5)
    comp = comprometido.get(x["codigo"], 0)
    for j in range(n_lotes):
        antig = int(rng.integers(10, 300)) if rng.random() > 0.08 else int(rng.integers(500, 1300))
        lote = f"{(HOY - timedelta(days=antig)):%Y%m%d}{j + 1:03d}" if rng.random() > 0.1 \
            else f"L{int(rng.integers(1_000_000, 9_999_999))}"
        cant = round(total / n_lotes, 2)
        filas.append([cod_txt(x["codigo"]), x["nombre"], "VENTAS", lote, random.choice(ubic),
                      pres, f"{cant:.2f}", f"{comp if j == 0 else 0:.2f}"])
    if n_lotes == 0 and comp:
        filas.append([cod_txt(x["codigo"]), x["nombre"], "VENTAS", "", "", pres, "0.00", f"{comp:.2f}"])
    if x["tipo"] == "FABRICADO" and rng.random() < 0.3:
        filas.append([cod_txt(x["codigo"]), x["nombre"], "PRODUCCION", f"{HOY:%Y%m%d}{int(rng.integers(1, 9)):03d}",
                      "G19", "KG", f"{x['kg_mes'] * rng.uniform(0.1, 0.8):.2f}", "0.00"])
filas.append(["8888", "PRODUCTO NO CREADO", "VENTAS", "20260101001", "A1", "KG", "3.00", "0.00"])
escribir("inventario.csv", ["Referencia", "Descripcion", "Bodega", "Lote", "Ubicacion",
                            "Presentacion", "Cantidad", "Comprometido"], filas)


# ----------------------------------------------------------------------
# 8. Cartera (corte de hoy)
# ----------------------------------------------------------------------
nom_vend = {v[0]: v[1] for v in vendedores}
saldo_fact = {}
for r in facturas:
    if r[2].startswith("FE"):
        saldo_fact.setdefault(r[2], [r[0], r[1], 0.0])
        saldo_fact[r[2]][2] += r[6]
filas = []
for num, (f, nit, val) in saldo_fact.items():
    c = nit_cli[nit]
    if c["dias"] == 0:
        continue
    venc = f + timedelta(days=c["dias"])
    edad = (HOY - f).days
    pendiente = edad <= c["dias"] + 5 or (c["moroso"] and edad <= c["dias"] + 150 and rng.random() < 0.7)
    if not pendiente:
        continue
    saldo = val if rng.random() > 0.15 else val * rng.uniform(0.3, 0.8)
    vend = "QUIMICA ANDINA (CASA)" if rng.random() < 0.05 else nom_vend[c["vendedor"]]
    filas.append([num, c["nombre"], vend, nit_comas(nit), fecha_mdy(f), fecha_mdy(venc),
                  (HOY - venc).days, fmt_us(saldo)])
filas.append(["FE-77777777", "CLIENTE FANTASMA", nom_vend["V01"], "123,456,789",
              fecha_mdy(HOY - timedelta(days=40)), fecha_mdy(HOY - timedelta(days=10)), 10, "1,500,000"])
escribir("cartera.csv", ["Documento", "Cliente", "Vendedor", "NIT cliente",
                         "Fecha documento", "Fecha vencimiento", "Dias vencidos", "Saldo"], filas)


# ----------------------------------------------------------------------
# 9. Cotizaciones (último año: ';' , d/m/a, $1.062.000,00)
# ----------------------------------------------------------------------
filas, n_ctz = [], 5000
for _ in range(700):
    c = random.choice([c for c in clientes if c["estado"] != "INACTIVO"])
    f = HOY - timedelta(days=int(rng.integers(0, 365)))
    n_ctz += 1
    edad = (HOY - f).days
    if edad < 5 and rng.random() < 0.4:
        estado = "En elaboración"
    else:
        estado = rng.choice(["Pedidas", "Perdidas", "Aprobadas"], p=[0.45, 0.15, 0.40])
    for idx in rng.choice(c["canasta"], size=min(len(c["canasta"]), int(rng.integers(1, 4))), replace=False):
        x = activos[idx]
        if x["lanzamiento"] > f: continue
        kg = max(x["venta_min"], round(x["kg_mes"] * c["tamano"] * rng.uniform(0.3, 1.2) / 6))
        pl = precio_lista(x, c["lista"], f)
        precio = pl if rng.random() < 0.65 else round(pl * rng.uniform(0.90, 0.99), -2)
        filas.append(["001", f"CTZ-{n_ctz:08d}", fecha_dmy(f), estado, nit_comas(c["nit"]),
                      c["vendedor"], cod_txt(x["codigo"]), str(kg).replace(".", ","),
                      fmt_co(precio), fmt_co(kg * precio)])
escribir("cotizaciones.csv", ["Sede", "Cotizacion", "Fecha", "Estado", "NIT cliente", "Vendedor",
                              "Referencia", "Cantidad", "Precio unitario", "Valor subtotal"],
         filas, delim=";")

print(f"\nDatos ficticios de Química Andina S.A.S. generados en '{OUT}/' (hasta {HOY}, semilla {args.semilla}).")
