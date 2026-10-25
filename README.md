# Sistema comercial · Química Andina S.A.S. *(empresa ficticia)*

Proyecto de la **Especialización en Ciencia de Datos y Analítica**: un modelo genérico de gestión comercial para
un distribuidor B2B de materias primas, construido con datos sintéticos que imitan las exportaciones de un ERP.

> **Aviso:** empresa, productos (`PRODUCTO-0001`…), clientes (`CLIENTE-0001`…), vendedores, precios y cifras son
> 100 % ficticios y generados por `generar_datos.py`. El proyecto no contiene ni se basa en información
> confidencial de ninguna empresa.

**Demo:** [cotizador-quimica-andina-demo.streamlit.app](https://cotizador-quimica-andina-demo.streamlit.app) (usuario de prueba disponible a solicitud)

## El problema
Cotizar exigía cruzar a mano varias fuentes del ERP: lista de precios, precios especiales, última compra,
inventario, cartera y tiempos de fabricación. Cada cotización tomaba minutos y dependía de la memoria del asesor.

## La solución
```
ERP (CSV diarios) ──► carga validada (SQL) ──► PostgreSQL en la nube (Neon)
                                                  ├─► Cotizador web (Streamlit)
                                                  ├─► Tableros (Power BI / Looker Studio)
                                                  └─► Forecast de demanda (Python)
```
- **Carga diaria idempotente** en una sola transacción: limpieza de formatos del ERP, validación fila por fila,
  registro de errores, historial de precios y fotografías diarias de inventario y cartera.
- **Reglas de negocio en la base**: facturas inmutables (las correcciones van por nota crédito), vendedor del
  documento y no del cliente, historial de lista de precios y vendedor, detección de cambios de NIT.
- **Cotizador**: precio sugerido (especial → lista), última compra, disponibilidad, fecha de entrega, alertas
  de cartera y venta mínima; genera una **propuesta de precios** con consecutivo propio en PDF, Excel para el
  ERP y texto para WhatsApp.

## Tecnologías
PostgreSQL (PL/pgSQL, vistas, procedimientos) · Neon · Python (pandas, psycopg2, reportlab, openpyxl) ·
Streamlit · psql / Windows batch

## Archivos
| Archivo | Qué es |
|---|---|
| `qa_01` … `qa_05`, `qa_09` … `qa_11` | Estructura de la base, cotizador, carga, propuestas, forecast y usuario de la app |
| `importar.sql`, `cargar.bat` | Carga diaria de los CSV |
| `cotizador.py`, `propuesta.py` | App web y documentos de la propuesta |
| `generar_datos.py`, `simular_dia.py` | Datos sintéticos y simulación de un día de operación |
| `generar_clave.py` | Crea las credenciales de los usuarios de la app |
| `LEEME.md` | Manual de instalación y operación |

Todos los datos son ficticios. No se incluyen datos ni contraseñas en este repositorio.
