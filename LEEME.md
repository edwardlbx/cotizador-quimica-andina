# Kit de carga — Química Andina S.A.S. (datos ficticios)

## Contenido
| Archivo | Para qué |
|---|---|
| `qa_01_esquema.sql` | Tablas, vistas y funciones del esquema `qa` |
| `qa_02_cotizar.sql` | Función `qa.fn_cotizar` (cotización con cantidades) |
| `qa_03_powerbi.sql` | Vistas de apoyo para Power BI |
| `qa_04_carga.sql` | **Kit de carga**: tablas de paso, limpieza, validación, registro de errores |
| `qa_05_propuestas.sql` | Propuestas de precios (PP): consecutivo, registro y enlace con la cotización del ERP |
| `qa_09`, `qa_10`, `qa_11` | Migración de documentos (inofensiva en una base nueva), base del forecast y usuario de solo lectura `cotizador` |
| `simular_dia.py` | Simula un día de operación: lee la base y deja en `entrada/` los CSV de ese día |
| `importar.sql` | Script que ejecuta `cargar.bat` (no se corre a mano) |
| `cargar.bat` | Carga diaria: doble clic |
| `generar_datos.py` | Genera los CSV ficticios en `entrada/` |
| `cotizador.py`, `requirements.txt` | Cotizador en Streamlit |
| `propuesta.py`, `logo_quimica_andina.png` | PDF de la propuesta, Excel para el ERP, texto para WhatsApp y logo |

## Instalación (una sola vez)
Dos bases con la misma estructura:
- **Neon** (`neondb`, en la nube): **oficial**. La usan el cotizador, la carga diaria (opción 1 de `cargar.bat`), el forecast y los tableros.
- `qa_pruebas` (PostgreSQL de este PC): **laboratorio** para ensayar cambios antes de pasarlos a Neon.

Conexión a Neon: la contraseña vive en `%APPDATA%\postgresql\pgpass.conf` (para `cargar.bat` y psql) y en `%USERPROFILE%\.streamlit\secrets.toml` (para el cotizador y `simular_dia.py`). Ninguno de los dos va en Google Drive ni en GitHub.

Zona horaria: Neon trabaja en UTC. Cada base nueva en Neon debe configurarse una vez con `ALTER DATABASE neondb SET timezone TO 'America/Bogota';` — si no, después de las 7 p. m. la base ya cree que es el día siguiente (fechas de corte, vigencias y días de mora).

En la terminal de VS Code, dentro de esta carpeta:
```powershell
$psql = "C:\Program Files\PostgreSQL\16\bin\psql.exe"
$env:PGCLIENTENCODING = "UTF8"
foreach ($base in "qa_pruebas") {   # en Neon se instaló copiando la base (pg_dump)
  & $psql -h 127.0.0.1 -U postgres -c "CREATE DATABASE $base"
  foreach ($f in "qa_01_esquema.sql","qa_02_cotizar.sql","qa_03_powerbi.sql","qa_04_carga.sql","qa_05_propuestas.sql") {
    & $psql -h 127.0.0.1 -U postgres -d $base -v ON_ERROR_STOP=1 -q -f $f
  }
  Write-Host "OK $base"
}
```
Contraseña guardada (para que `cargar.bat` no la pida):
```powershell
New-Item -ItemType Directory -Force "$env:APPDATA\postgresql" | Out-Null
Set-Content "$env:APPDATA\postgresql\pgpass.conf" "127.0.0.1:5432:*:postgres:TU_CONTRASEÑA"
```

## Uso
1. `python generar_datos.py` → crea los CSV en `entrada/`
2. Doble clic en `cargar.bat` → pregunta la base (1 = Neon, 2 = qa_pruebas), carga y mueve los CSV a `procesados/<fecha>_<base>/`
   - Para cargar la misma información en la otra base, vuelve a correr `python generar_datos.py` (con la misma semilla genera los mismos datos).
   - Programador de tareas: `cargar.bat auto` (carga a Neon sin pausas)
   - Simular un día de operación: `python simular_dia.py --fecha AAAA-MM-DD` (en Neon) o `--lab` (en qa_pruebas)
3. Errores de filas: `procesados/errores_<fecha>.csv` o `SELECT * FROM qa.v_errores_ultima_carga;`
4. `python -m streamlit run cotizador.py` → cotizar y generar la **propuesta de precios (PP)**: PDF, Excel para el ERP y texto para WhatsApp
5. Cuando el cliente acepte: crear la cotización formal en el ERP y enlazarla en el panel izquierdo → «Propuestas emitidas (PP)»

## Reglas de la carga
- Toda la corrida es una transacción: si algo falla, la base no cambia.
- Filas con problemas (cliente o producto inexistente, fecha vacía…) no se cargan y quedan en `qa.carga_errores`; el resto sí.
- Recargar el mismo archivo no duplica.

| Tipo | Archivos | Regla |
|---|---|---|
| **Documentos inmutables** | facturas y notas crédito | Solo se insertan. Si llega una factura ya cargada, se ignora; si llega con datos distintos, queda una ADVERTENCIA y se conserva la original (las correcciones van por nota crédito). Si una línea tiene error, se rechaza la factura **completa** y entra entera cuando se corrija. |
| **Documentos con estado** | pedidos, cotizaciones | Se insertan y actualizan (estado, despachos). Conservan el vendedor del documento. |
| **Maestros** | clientes, productos, precios, vendedores | Se actualizan. Cambios de lista o vendedor del cliente quedan en `qa.clientes_historial`. |
| **Fotografías** | inventario, cartera | Reemplazan la foto del día. La cartera lleva el vendedor responsable del cobro **hoy**. |

- **Vendedor de una factura**: el que trae la factura; si no viene, el de su pedido; si no, el que tenía el cliente en esa fecha (historial). Nunca cambia después.
- **Clasificación del precio** (LISTA / ESPECIAL / ÚNICA VEZ): contra la lista que tenía el cliente en la fecha del documento.
- **Cambio de NIT**: es un cliente nuevo. Para unir su historia: `CALL qa.pr_enlazar_sucesor('NIT_ANTIGUO','NIT_NUEVO');` (el antiguo queda INACTIVO). Para análisis y forecast usa `qa.v_clientes_consolidado`.
- Precios: solo se agrega una fila si el precio cambió (historial).
- No se tocan los datos que registra el área comercial: tiempos de fabricación (archivo propio), contactos, precios especiales, motivo de pérdida.

## Formatos que espera cada CSV
| Archivo | Separador | Números | Fechas |
|---|---|---|---|
| cotizaciones.csv | `;` | `$1.062.000,00` | dd/mm/aaaa |
| pedidos.csv | `,` | `71.00` | dd/mm/aaaa |
| precios.csv | `,` | `219,500` | dd/mm/aaaa (vigente desde) |
| facturas.csv, cartera.csv | `,` | `2,135,455` / `236.00` | **mm/dd/aaaa** |
| resto | `,` | — | — |

Columnas que se usan por posición (los nombres del encabezado no importan). En `productos.csv` la columna *Línea* trae la familia (`Línea A` → A); el nombre del producto es libre.

`facturas.csv` (formato oct-2026) trae 11 columnas: `Fecha, NIT cliente, Documento, Producto, Cantidad, Valor subtotal, Lote, Pedido, Vendedor, Fecha vencimiento, Factura referencia`. La última solo se llena en notas crédito (la factura que corrigen). `cargar.bat` reconoce solo si el archivo trae el formato nuevo o el anterior (8 columnas).

## Cómo exportar del ERP (para quien descarga los archivos)
1. **Diario**, al cierre del día: maestros y fotografías completos; facturas de los últimos 90 días; pedidos y cotizaciones de los últimos 120 días **más todos los pedidos abiertos**. **Mensual**: el histórico completo de facturas, pedidos y cotizaciones, para reconciliar.
2. Exportar **todos los archivos en el mismo momento**.
3. Usar siempre **la misma plantilla guardada** en el ERP (mismas columnas, mismo orden, mismos filtros).
4. **Incluir los documentos anulados** con su estado; no filtrarlos.
5. **No abrir y guardar los CSV en Excel** antes de cargarlos: Excel convierte `0201` en `201`, los NIT en notación científica y cambia las fechas.
6. No renombrar los archivos.

Codificación: UTF-8. Si un archivo real llega con otro formato, se ajusta su procedimiento en `qa_04_carga.sql`.
