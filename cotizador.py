"""
Cotizador Química Andina
---------------------
App local en Streamlit que usa la base PostgreSQL (esquema qa) y la función
qa.fn_cotizar para armar cotizaciones: cliente + productos + cantidades.
Emite PROPUESTAS DE PRECIOS (PP) informativas: PDF, Excel para el ERP y texto
para WhatsApp. La cotización formal se sigue emitiendo en el ERP.

Ejecutar en la terminal, dentro de la carpeta quimica_andina:
    streamlit run cotizador.py
"""
from datetime import date

import hashlib
import hmac
import json

import pandas as pd
import psycopg2
import streamlit as st

import propuesta as doc_pp

st.set_page_config(page_title="Cotizador Química Andina", page_icon="🧪", layout="wide")


# ----------------------------------------------------------------------
# Acceso (usuarios y contraseñas en secrets.toml, sección [usuarios])
# ----------------------------------------------------------------------
def clave_valida(clave: str, guardada: str) -> bool:
    """guardada = 'pbkdf2$iteraciones$sal$hash' (se genera con generar_clave.py)"""
    try:
        _, it, sal, h = str(guardada).split("$")
        calc = hashlib.pbkdf2_hmac("sha256", clave.encode(), bytes.fromhex(sal), int(it)).hex()
        return hmac.compare_digest(calc, h)
    except Exception:
        return False


def control_acceso() -> None:
    """Si secrets.toml trae [usuarios], pide iniciar sesión. Sin esa sección (uso local) no pide nada."""
    try:
        usuarios = {k.lower(): v for k, v in dict(st.secrets["usuarios"]).items()}
    except Exception:
        return
    if st.session_state.get("usuario"):
        st.sidebar.caption(f"Sesión: **{st.session_state.usuario}**")
        if st.sidebar.button("Cerrar sesión"):
            st.session_state.clear()
            st.rerun()
        return
    _, centro, _ = st.columns([1, 1.2, 1])
    with centro:
        st.subheader("Cotizador Química Andina")
        st.caption("Empresa ficticia · proyecto académico de ciencia de datos")
        with st.form("login"):
            u = st.text_input("Usuario").strip().lower()
            c = st.text_input("Contraseña", type="password")
            entrar = st.form_submit_button("Entrar", type="primary", width="stretch")
        if entrar:
            if u in usuarios and clave_valida(c, usuarios[u]):
                st.session_state.usuario = u
                st.rerun()
            st.error("Usuario o contraseña incorrectos.")
    st.stop()


control_acceso()


# ----------------------------------------------------------------------
# Conexión
# ----------------------------------------------------------------------
def config_conexion() -> dict:
    """Toma los datos de .streamlit/secrets.toml si existen; si no, del panel lateral."""
    try:
        cfg = dict(st.secrets["postgres"])
        st.sidebar.success(f"Conectado a **{cfg.get('dbname')}**")
        return cfg
    except Exception:
        pass
    st.sidebar.header("Conexión")
    return {
        "host": st.sidebar.text_input("Servidor", "127.0.0.1"),
        "port": st.sidebar.number_input("Puerto", value=5432, step=1),
        "dbname": st.sidebar.selectbox("Base de datos", ["qa_pruebas"]),   # Neon se toma de secrets.toml
        "user": st.sidebar.text_input("Usuario", "postgres"),
        "password": st.sidebar.text_input("Contraseña", type="password"),
    }


def consultar(cfg: dict, sql: str, params=None) -> pd.DataFrame:
    """Ejecuta SQL y devuelve el resultado (si lo hay). Confirma (commit) los cambios."""
    try:
        conn = psycopg2.connect(**cfg, connect_timeout=5)
    except UnicodeDecodeError:
        # PostgreSQL en español (Windows) responde con tildes en otra codificación y psycopg2
        # no puede leer el mensaje. Casi siempre es contraseña incorrecta o base inexistente.
        raise psycopg2.OperationalError(
            f"Conexión rechazada: contraseña incorrecta o la base '{cfg.get('dbname')}' no existe.")
    try:
        with conn, conn.cursor() as cur:
            cur.execute(sql, params)
            if cur.description is None:
                return pd.DataFrame()
            cols = [c[0] for c in cur.description]
            return pd.DataFrame(cur.fetchall(), columns=cols)
    finally:
        conn.close()


@st.cache_data(ttl=300, show_spinner=False)
def cargar_clientes(cfg_items: tuple) -> pd.DataFrame:
    return consultar(dict(cfg_items), """
        SELECT cliente_id, nombre, estado, lista_precio, ciudad, condicion_pago_dias, vendedor_id
        FROM qa.clientes ORDER BY nombre""")


@st.cache_data(ttl=300, show_spinner=False)
def cargar_vendedores(cfg_items: tuple) -> pd.DataFrame:
    return consultar(dict(cfg_items), """
        SELECT vendedor_id, nombre FROM qa.vendedores WHERE activo ORDER BY nombre""")


@st.cache_data(ttl=300, show_spinner=False)
def cargar_productos(cfg_items: tuple) -> pd.DataFrame:
    return consultar(dict(cfg_items), """
        SELECT producto_id, nombre, unidad_medida
        FROM qa.productos WHERE estado = 'ACTIVO' ORDER BY producto_id""")


# ----------------------------------------------------------------------
# Utilidades de formato
# ----------------------------------------------------------------------
def cop(x) -> str:
    if x is None or pd.isna(x):
        return "—"
    return "$" + f"{float(x):,.0f}".replace(",", ".")


def limpio(x):
    """Valor vacío de la base (None / NaN / <NA>) -> None. Con pandas 3 los vacíos llegan como NaN,
    y NaN cuenta como "verdadero" en un if: por eso aparecía el texto «nan»."""
    try:
        return None if x is None or pd.isna(x) else x
    except (TypeError, ValueError):
        return x


def num(x, dec=2) -> str:
    if x is None or pd.isna(x):
        return "—"
    s = f"{float(x):,.{dec}f}".replace(",", "X").replace(".", ",").replace("X", ".")
    return s.rstrip("0").rstrip(",") if "," in s else s


def nivel_alerta(texto: str) -> str:
    t = texto.lower()
    if "bloqueado" in t or "no existe" in t or "cartera vencida" in t:
        return "error"
    if any(k in t for k in ("sobrecomprometido", "sin inventario", "sin stock", "debajo", "falta", "sin precio")):
        return "warning"
    return "info"


def nit_txt(n) -> str:
    """901802759 -> 901.802.759"""
    n = str(n)
    return f"{int(n):,}".replace(",", ".") if n.isdigit() else n


def nombre_propio(t: str) -> str:
    """'MARIA FERNANDA CARDENAS LOPEZ' -> 'Maria Fernanda Cardenas Lopez'"""
    return " ".join(w.capitalize() for w in str(t).split())


PARTICULAS = {"DE", "DEL", "LA", "LAS", "LOS", "SAN", "Y"}


def nombre_natural(t: str) -> str:
    """El ERP guarda 'APELLIDOS NOMBRES'; se muestra 'NOMBRES APELLIDOS'.
    'CARDENAS LOPEZ MARIA FERNANDA' -> 'MARIA FERNANDA CARDENAS LOPEZ'
    'RIVAS MEJIA SANTIAGO'          -> 'SANTIAGO RIVAS MEJIA'
    'DE LA HOZ PEREZ ANA'           -> 'ANA DE LA HOZ PEREZ'   (partículas van con su apellido)
    Nombres que no son de persona (p. ej. 'QUIMICA ANDINA (CASA)') quedan igual."""
    palabras = str(t).split()
    if "(" in str(t) or len(palabras) < 3:
        return str(t)
    grupos, actual = [], []
    for w in palabras:                       # agrupa "DE LA HOZ" como un solo apellido
        actual.append(w)
        if w.upper() not in PARTICULAS:
            grupos.append(" ".join(actual))
            actual = []
    if actual:
        grupos.append(" ".join(actual))
    if len(grupos) < 3:
        return str(t)
    apellidos, nombres = grupos[:2], grupos[2:]
    return " ".join(nombres + apellidos)


def a_numero(x):
    """'$52.100' / '52100' / '52.100,50' -> 52100.0 ; vacío o inválido -> None"""
    if x is None or (isinstance(x, float) and pd.isna(x)):
        return None
    if isinstance(x, (int, float)):
        return float(x)
    t = str(x).strip().replace("$", "").replace(" ", "")
    if not t:
        return None
    if "," in t:                             # formato colombiano: punto = miles, coma = decimales
        t = t.replace(".", "").replace(",", ".")
    else:
        t = t.replace(".", "")
    try:
        return float(t)
    except ValueError:
        return None


# ----------------------------------------------------------------------
# Interfaz
# ----------------------------------------------------------------------
from pathlib import Path
_logo = Path(__file__).with_name("logo_quimica_andina.png")
if _logo.exists():
    st.image(str(_logo), width=300)
st.title("Cotizador")

# Recuadro de la propuesta de precios: color de marca para distinguirlo del resto
st.markdown("""
<style>
.st-key-caja_propuesta {
    background: rgba(18, 144, 123, 0.14);      /* verde de la marca: no se confunde con las alertas */
    border: 1px solid rgba(18, 144, 123, 0.55);
    border-left: 6px solid #12907B;
    border-radius: 0.6rem;
    padding: 1.1rem 1.3rem 1.3rem 1.3rem;
}
</style>""", unsafe_allow_html=True)

cfg = config_conexion()
if not cfg.get("password"):
    st.info("Escribe la contraseña de PostgreSQL en el panel de la izquierda para empezar.")
    st.stop()

cfg_key = tuple(sorted(cfg.items()))
try:
    clientes = cargar_clientes(cfg_key)
    productos = cargar_productos(cfg_key)
except psycopg2.OperationalError as e:
    st.error(f"No pude conectarme a la base de datos. Revisa servidor y contraseña.\n\n{e}")
    st.stop()
except UnicodeDecodeError:
    # En Windows con PostgreSQL en español, el mensaje de error del servidor llega con tildes
    # en otra codificación y psycopg2 no lo puede leer. Casi siempre es contraseña o base.
    st.error("No pude conectarme a la base de datos. Lo más probable: **contraseña incorrecta** "
             f"o la base **{cfg.get('dbname')}** no existe. Revisa el panel de la izquierda.")
    st.stop()
except psycopg2.Error as e:
    st.error(f"La base respondió con un error. ¿Instalaste los scripts qa_01 a qa_04?\n\n{e}")
    st.stop()

try:  # fecha de los datos (requiere qa_04_carga.sql)
    est = consultar(cfg, "SELECT ultima_carga, corte_inventario FROM qa.v_estado_datos")
    if not est.empty and est.iloc[0]["ultima_carga"] is not None:
        st.caption(f"Datos actualizados: {est.iloc[0]['ultima_carga']:%d/%m/%Y %H:%M} · "
                   f"inventario y cartera al {est.iloc[0]['corte_inventario']:%d/%m/%Y}")
except psycopg2.Error:
    pass

# --- Panel lateral: propuestas emitidas y enlace con la cotización formal ---
with st.sidebar.expander("📄 Propuestas emitidas (PP)"):
    hay_tabla = True
    try:
        props = consultar(cfg, """
            SELECT numero_propuesta, fecha, cliente, valor_subtotal, estado, numero_cotizacion_erp
            FROM qa.v_propuestas ORDER BY numero_propuesta DESC LIMIT 30""")
    except psycopg2.Error:
        props, hay_tabla = pd.DataFrame(), False
        st.caption("Instala qa_05_propuestas.sql para usar las propuestas.")
    if not props.empty:
        st.dataframe(props.rename(columns={"numero_propuesta": "PP", "valor_subtotal": "Valor",
                                           "numero_cotizacion_erp": "Cotización ERP"}),
                     hide_index=True, height=200)
        pend = props[props["numero_cotizacion_erp"].isna()]["numero_propuesta"].tolist()
        if pend:
            st.write("**Enlazar con la cotización formal del ERP**")
            pp_sel = st.selectbox("Propuesta", pend, key="pp_enlazar")
            ctz = st.text_input("N.º cotización ERP", placeholder="CTZ-00006001", key="ctz_enlazar")
            if st.button("Guardar enlace"):
                if not ctz.strip():
                    st.warning("Escribe el número de la cotización del ERP.")
                else:
                    consultar(cfg, "CALL qa.pr_formalizar_propuesta(%s, %s)", (pp_sel, ctz))
                    st.success(f"{pp_sel} enlazada con {ctz.strip().upper()}.")
                    st.rerun()
    elif hay_tabla:
        st.caption("Todavía no hay propuestas.")

if clientes.empty or productos.empty:
    st.warning("La base no tiene clientes o productos cargados todavía.")
    st.stop()

# --- Cliente ---
clientes["etiqueta"] = (clientes["nombre"] + " — NIT " + clientes["cliente_id"]
                        + " · Lista " + clientes["lista_precio"].astype(str)
                        + clientes["estado"].map(lambda e: "" if e == "ACTIVO" else f" · {e}"))
etiqueta_cli = st.selectbox("Cliente", clientes["etiqueta"].tolist(), index=None,
                            placeholder="Escribe para buscar un cliente…")

# --- Productos y cantidades ---
productos["etiqueta"] = productos["producto_id"] + " - " + productos["nombre"]
VACIO = pd.DataFrame({"Producto": pd.Series([None], dtype="object"),
                      "Cantidad": pd.Series([None], dtype="float")})
for k, v in {"lineas": VACIO.copy(), "editor_ver": 0, "hab_ver": 0, "pendiente": None, "aviso": None}.items():
    if k not in st.session_state:
        st.session_state[k] = v

# --- Productos que el cliente ya compra (para elegir) ---
if etiqueta_cli is not None:
    nit_sel = clientes.loc[clientes["etiqueta"] == etiqueta_cli, "cliente_id"].iloc[0]
    clave_hab = f"hab_{nit_sel}"
    if clave_hab not in st.session_state:          # se consulta una vez por cliente
        h = consultar(cfg, """
            SELECT v.producto_id || ' - ' || p.nombre AS "Producto",
                   count(DISTINCT v.numero_factura)  AS "Compras (12 m)",
                   max(v.fecha)                       AS "Última compra",
                   round(percentile_cont(0.5) WITHIN GROUP (ORDER BY v.cantidad)::numeric, 2) AS "Cant. típica",
                   (array_agg(v.precio_unitario ORDER BY v.fecha DESC))[1] AS "Último precio"
            FROM qa.v_ventas v JOIN qa.productos p USING (producto_id)
            WHERE v.cliente_id = %s AND v.tipo = 'FV' AND p.estado = 'ACTIVO'
              AND v.fecha >= CURRENT_DATE - INTERVAL '12 months'
            GROUP BY 1 ORDER BY 2 DESC, 3 DESC""", (nit_sel,))
        h.insert(0, "Agregar", False)
        h["Cant. típica"] = h["Cant. típica"].map(num)
        h["Última compra"] = pd.to_datetime(h["Última compra"]).dt.strftime("%d/%m/%Y")
        h["Último precio"] = h["Último precio"].map(cop)
        st.session_state[clave_hab] = h
    hab = st.session_state[clave_hab]

    with st.expander(f"Productos que este cliente ya compra ({len(hab)})", expanded=False):
        if hab.empty:
            st.caption("Este cliente no tiene compras en los últimos 12 meses.")
        else:
            filtro = st.text_input("🔍 Buscar producto", key=f"filtro_{nit_sel}",
                                   placeholder="Nombre o código, ej.: lulo, 3275")
            visibles = hab[hab["Producto"].str.contains(filtro, case=False, regex=False)] if filtro else hab
            editado = st.data_editor(
                visibles, hide_index=True, width="stretch",
                height=min(38 * (len(visibles) + 1), 330),
                disabled=["Producto", "Compras (12 m)", "Última compra", "Cant. típica", "Último precio"],
                column_config={
                    "Agregar": st.column_config.CheckboxColumn("Agregar", width="small"),
                    "Cant. típica": st.column_config.TextColumn(
                        "Cant. típica", help="Mediana de sus compras: solo como referencia"),
                },
                key=f"hab_editor_{nit_sel}_{filtro}_{st.session_state.hab_ver}")
            # guarda lo marcado/editado, aunque luego se cambie el filtro
            hab.loc[editado.index, "Agregar"] = editado["Agregar"]

            b1, b2, _ = st.columns([1, 1, 3])
            if b1.button("Marcar todos", help="Marca los productos visibles (respeta la búsqueda)"):
                hab.loc[visibles.index, "Agregar"] = True
                st.session_state.hab_ver += 1
                st.rerun()
            if b2.button("Agregar seleccionados", type="primary"):
                elegidos = hab[hab["Agregar"]]
                if elegidos.empty:
                    st.warning("Marca al menos un producto.")
                else:
                    # la cantidad queda vacía: la escribe el asesor en la tabla de la cotización
                    st.session_state.pendiente = pd.DataFrame({
                        "Producto": elegidos["Producto"].values,
                        "Cantidad": pd.Series([None] * len(elegidos), dtype="float")})
                    hab["Agregar"] = False                     # desmarca para la próxima vez
                    st.session_state.hab_ver += 1

# --- Tabla de la cotización ---
st.write("**Productos y cantidades**")
if st.session_state.aviso:
    st.caption(st.session_state.aviso)
lineas = st.data_editor(
    st.session_state.lineas,
    num_rows="dynamic",
    width="stretch",
    column_config={
        "Producto": st.column_config.SelectboxColumn(
            "Producto", options=productos["etiqueta"].tolist(), required=True, width="large"),
        "Cantidad": st.column_config.NumberColumn(
            "Cantidad", min_value=0.0, step=0.5, format="%.2f", required=True),
    },
    key=f"editor_lineas_{st.session_state.editor_ver}",
)

# Suma los productos elegidos a lo que ya había (sin borrar ni duplicar)
if st.session_state.pendiente is not None:
    actuales = lineas.dropna(subset=["Producto"])
    nuevos = st.session_state.pendiente
    repetidos = nuevos[nuevos["Producto"].isin(actuales["Producto"])]
    nuevos = nuevos[~nuevos["Producto"].isin(actuales["Producto"])]
    st.session_state.lineas = pd.concat([actuales, nuevos], ignore_index=True)
    msj = f"Se agregaron {len(nuevos)} producto(s): escribe la cantidad de cada uno antes de cotizar."
    if not repetidos.empty:
        msj += " Ya estaban en la cotización: " + ", ".join(p.split(" - ")[0] for p in repetidos["Producto"]) + "."
    st.session_state.aviso = msj
    st.session_state.pendiente = None
    st.session_state.editor_ver += 1
    st.rerun()

if st.button("Limpiar tabla"):
    st.session_state.lineas = VACIO.copy()
    st.session_state.aviso = None
    st.session_state.editor_ver += 1
    st.rerun()

if st.button("Cotizar", type="primary", key="btn_cotizar"):
    error = None
    if etiqueta_cli is None:
        error = "Elige un cliente."
    else:
        sin_cantidad = lineas[lineas["Producto"].notna() & ~(lineas["Cantidad"].fillna(0) > 0)]
        validas = lineas.dropna(subset=["Producto", "Cantidad"])
        validas = validas[validas["Cantidad"] > 0]
        if not sin_cantidad.empty:
            error = ("Falta la cantidad de: " + ", ".join(p.split(" - ")[0] for p in sin_cantidad["Producto"])
                     + ". Escríbela en la tabla (o elimina la fila) y vuelve a cotizar.")
        elif validas.empty:
            error = "Agrega al menos un producto con cantidad mayor que cero."
    if error:
        st.error(error)
        st.session_state.cot = None
        st.stop()
    st.session_state.cot = {"etiqueta": etiqueta_cli,
                            "codigos": [p.split(" - ")[0] for p in validas["Producto"]],
                            "cantidades": [float(c) for c in validas["Cantidad"]]}
    st.session_state.pp = None                       # nueva cotización = nueva propuesta

cot = st.session_state.get("cot")
if not cot:
    st.caption("Agrega filas con el «+» de la tabla. La cantidad va en la unidad del producto (kg).")
    st.stop()
if cot["etiqueta"] != etiqueta_cli:
    st.info("Cambiaste de cliente: presiona **Cotizar** para ver su cotización.")
    st.stop()
_actual = lineas.dropna(subset=["Producto", "Cantidad"])
if ([p.split(" - ")[0] for p in _actual["Producto"]] != cot["codigos"]
        or [float(c) for c in _actual["Cantidad"]] != cot["cantidades"]):
    st.warning("La tabla cambió desde la última cotización: presiona **Cotizar** para actualizar el resultado.")

cliente = clientes.loc[clientes["etiqueta"] == cot["etiqueta"]].iloc[0]
codigos, cantidades = cot["codigos"], cot["cantidades"]

# --- Consulta a la base ---
try:
    res = consultar(cfg, "SELECT * FROM qa.fn_cotizar(%s::varchar, %s::text[], %s::numeric[])",
                    (cliente["cliente_id"], codigos, cantidades))
    ficha = consultar(cfg, "SELECT * FROM qa.v_ficha_cliente WHERE cliente_id = %s",
                      (cliente["cliente_id"],))
except psycopg2.Error as e:
    st.error(f"Error al cotizar. ¿Instalaste qa_02_cotizar.sql?\n\n{e}")
    st.stop()

detalle = res[res["linea"].notna()].copy()
total = res.loc[res["linea"].isna(), "valor_estimado"].iloc[0]
f = ficha.iloc[0] if not ficha.empty else None

# --- Resultado: métricas ---
if cliente["estado"] == "BLOQUEADO":
    st.error("⛔ Cliente BLOQUEADO: confirma con Cartera antes de enviar la cotización.")

m1, m2, m3, m4 = st.columns(4)
m1.metric("Total estimado (sin IVA)", cop(total))
inmediatos = (detalle["entrega"] == "Inmediata (almacén)").sum()
m2.metric("Entrega inmediata", f"{inmediatos} de {len(detalle)}")
vencida = f["cartera_vencida"] if f is not None else 0
m3.metric("Cartera vencida", cop(vencida),
          delta=f"{int(f['max_dias_vencido'])} días" if f is not None and vencida else None,
          delta_color="inverse")
m4.metric("Ventas últimos 12 meses", cop(f["ventas_ultimos_12_meses"]) if f is not None else "—")

# --- Resultado: tabla ---
tabla = pd.DataFrame({
    "Producto": detalle["producto_id"] + " - " + detalle["producto"].fillna("¿?"),
    "Cantidad": detalle["cantidad"].map(num),
    "Precio sugerido": detalle["precio_sugerido"].map(cop),
    "Origen precio": detalle["origen_precio"],
    "Último precio pagado": detalle["precio_ultima_compra"].map(cop),
    "Valor": detalle["valor_estimado"].map(cop),
    "Disponible": detalle["disponible"].map(num),
    "Faltante": detalle["faltante"].map(num),
    "Entrega": detalle["entrega"],
})
st.dataframe(tabla, hide_index=True, width="stretch")

# --- Resultado: últimas 3 compras del cliente por producto ---
st.subheader("Últimas compras de estos productos")
try:
    hist = consultar(cfg, """
        SELECT producto_id, fecha, numero_factura, cantidad, precio_unitario, valor_subtotal
        FROM (SELECT v.*, row_number() OVER (PARTITION BY v.producto_id
                                             ORDER BY v.fecha DESC, v.numero_factura DESC) AS n
              FROM qa.v_ventas v
              WHERE v.cliente_id = %s AND v.tipo = 'FV' AND v.producto_id = ANY(%s)) x
        WHERE n <= 3
        ORDER BY producto_id, fecha DESC""",
        (cliente["cliente_id"], detalle["producto_id"].tolist()))
except psycopg2.Error as e:
    hist = pd.DataFrame()
    st.warning(f"No pude consultar el historial de compras.\n\n{e}")

for _, fila in detalle.iterrows():
    pid = fila["producto_id"]
    nombre = fila["producto"] if pd.notna(fila["producto"]) else "¿?"
    h = hist[hist["producto_id"] == pid] if not hist.empty else hist
    with st.expander(f"{pid} - {nombre}  ·  {len(h)} compra(s) registradas", expanded=False):
        if h.empty:
            st.caption("Este cliente no ha comprado este producto.")
            continue
        precio_hoy = fila["precio_sugerido"]
        st.dataframe(pd.DataFrame({
            "Fecha": pd.to_datetime(h["fecha"]).dt.strftime("%d/%m/%Y"),
            "Factura": h["numero_factura"],
            "Cantidad": h["cantidad"].map(num),
            "Precio pagado": h["precio_unitario"].map(cop),
            "Valor": h["valor_subtotal"].map(cop),
            "vs. precio sugerido hoy": h["precio_unitario"].map(
                lambda p: f"{(float(p) / float(precio_hoy) - 1) * 100:+.1f} %"
                if pd.notna(precio_hoy) and precio_hoy and pd.notna(p) else "—"),
        }), hide_index=True, width="stretch")

# --- Resultado: alertas ---
ALERTAS_CLIENTE = ("⛔ CLIENTE BLOQUEADO", "Cliente inactivo", "Cartera vencida")
de_cliente = []
for _, fila in detalle.iterrows():
    if not limpio(fila["alertas"]):
        continue
    for a in str(fila["alertas"]).split(" | "):
        if a.startswith(ALERTAS_CLIENTE):          # son del cliente: se muestran una sola vez
            if a not in de_cliente:
                de_cliente.append(a)
            continue
        getattr(st, nivel_alerta(a))(f"**{fila['producto_id']}** · {a}")
if de_cliente:
    st.error("**Cliente** · " + " · ".join(de_cliente))

# --- Propuesta de precios (PP) ---
st.divider()
with st.container(key="caja_propuesta"):
    st.subheader("Propuesta de precios para el cliente")
    st.caption("Documento informativo con consecutivo propio (PP). La cotización formal se emite en el ERP.")

    vendedores = cargar_vendedores(cfg_key).copy()
    vendedores["mostrar"] = vendedores["nombre"].map(nombre_natural)
    vendedores = vendedores.sort_values("mostrar").reset_index(drop=True)
    nombres_vend = vendedores["mostrar"].tolist()
    por_defecto = vendedores.index[vendedores["vendedor_id"] == cliente["vendedor_id"]].tolist()
    asesor = st.selectbox("Asesor", nombres_vend, index=por_defecto[0] if por_defecto else 0,
                          key=f"asesor_{cliente['cliente_id']}")

    precios = pd.DataFrame({
        "Código": detalle["producto_id"].values,
        "Producto": detalle["producto"].fillna("¿?").values,
        "Cantidad": detalle["cantidad"].map(num).values,
        "Precio sugerido": detalle["precio_sugerido"].map(cop).values,
        "Precio propuesta": detalle["precio_sugerido"].map(lambda x: "" if pd.isna(x) else cop(x)).values,
    })
    precios_ed = st.data_editor(
        precios, hide_index=True, width="stretch",
        disabled=["Código", "Producto", "Cantidad", "Precio sugerido"],
        column_config={
            "Precio propuesta": st.column_config.TextColumn(
                "Precio propuesta ✏️",
                help="Escríbelo si negociaste otro precio (ej. 55000 o $55.000). Es el que va en la propuesta."),
        },
        key=f"precios_pp_{hash(tuple(codigos))}_{hash(tuple(cantidades))}")
    precio_prop = precios_ed["Precio propuesta"].map(a_numero)
    subtotal_prop = sum(float(c) * p for c, p in zip(detalle["cantidad"], precio_prop) if p)
    st.markdown(f"**Subtotal de la propuesta:** {cop(subtotal_prop)} + IVA")
    obs = st.text_input("Observaciones para el cliente (opcional)", key="obs_pp")

    if cliente["estado"] == "BLOQUEADO":
        st.warning("El cliente está BLOQUEADO: confirma con Cartera antes de enviarle la propuesta.")

    if st.session_state.get("pp"):
        st.caption("Ya se generó la propuesta de esta cotización. Para otra, vuelve a presionar **Cotizar**.")
    if st.button("Generar propuesta (PP)", type="primary", disabled=st.session_state.get("pp") is not None):
        if precio_prop.isna().any() or (precio_prop.fillna(0) <= 0).any():
            st.error("Todos los productos deben tener un precio de propuesta válido y mayor que cero "
                     "(escríbelo como 55000 o $55.000).")
            st.stop()
        lineas_pp = []
        for (_, fila_d), precio in zip(detalle.iterrows(), precio_prop):
            precio = float(precio)
            sug = fila_d["precio_sugerido"]
            origen = (limpio(fila_d["origen_precio"]) or "LISTA") if pd.notna(sug) and abs(precio - float(sug)) < 0.5 else "MANUAL"
            lineas_pp.append({"producto_id": fila_d["producto_id"], "cantidad": float(fila_d["cantidad"]),
                              "precio": precio, "origen": origen, "entrega": limpio(fila_d["entrega"])})
        vend_id = vendedores.loc[vendedores["mostrar"] == asesor, "vendedor_id"].iloc[0]
        try:
            numero = consultar(cfg, "SELECT qa.fn_registrar_propuesta(%s, %s, %s::jsonb, %s) AS n",
                               (cliente["cliente_id"], vend_id, json.dumps(lineas_pp), obs or None)).iloc[0]["n"]
            cab = consultar(cfg, "SELECT fecha, vigente_hasta, valor_subtotal FROM qa.propuestas "
                                 "WHERE numero_propuesta = %s", (numero,)).iloc[0]
        except psycopg2.Error as e:
            st.error(f"No pude registrar la propuesta. ¿Instalaste qa_05_propuestas.sql?\n\n{e}")
            st.stop()
        um = dict(zip(productos["producto_id"], productos["unidad_medida"]))
        st.session_state.pp = {
            "numero": numero, "fecha": cab["fecha"], "vigente_hasta": cab["vigente_hasta"],
            "asesor": nombre_propio(asesor), "observaciones": obs or None,
            "cliente": {"nombre": cliente["nombre"], "nit": nit_txt(cliente["cliente_id"]),
                        "ciudad": limpio(cliente["ciudad"]),
                        "condicion_pago_dias": limpio(cliente["condicion_pago_dias"])},
            "lineas": [{"codigo": l["producto_id"], "descripcion": d,
                        "cantidad": l["cantidad"], "um": um.get(l["producto_id"], "KG"),
                        "precio": l["precio"], "valor": round(l["cantidad"] * l["precio"]), "entrega": l["entrega"]}
                       for l, d in zip(lineas_pp, precios_ed["Producto"])],
            "subtotal": float(cab["valor_subtotal"]),
        }
        st.rerun()

    pp = st.session_state.get("pp")
    if pp:
        st.success(f"Propuesta **{pp['numero']}** registrada · válida hasta el "
                   f"{pp['vigente_hasta']:%d/%m/%Y} · subtotal {cop(pp['subtotal'])} + IVA")
        d1, d2 = st.columns(2)
        d1.download_button("⬇️ Descargar PDF para el cliente", data=doc_pp.generar_pdf(pp),
                           file_name=f"{pp['numero']}_{cliente['cliente_id']}.pdf", mime="application/pdf",
                           type="primary")
        d2.download_button("⬇️ Excel para digitar en el ERP", data=doc_pp.excel_erp(pp),
                           file_name=f"{pp['numero']}_para_ERP.xlsx",
                           mime="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        st.write("**Texto para WhatsApp** (usa el ícono de copiar, arriba a la derecha del recuadro):")
        st.code(doc_pp.texto_whatsapp(pp), language=None)
        st.caption("Cuando el cliente acepte, crea la cotización formal en el ERP y enlázala desde "
                   "el panel izquierdo → «Propuestas emitidas (PP)».")
