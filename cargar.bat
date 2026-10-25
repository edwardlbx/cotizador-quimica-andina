@echo off
rem =====================================================================
rem  cargar.bat  -  Carga los CSV de "entrada" a PostgreSQL
rem
rem  Doble clic ............. pregunta a que base cargar
rem  cargar.bat neon ........ carga directo a Neon (oficial, en la nube)
rem  cargar.bat qa_pruebas .. carga directo a qa_pruebas (laboratorio en este PC)
rem  cargar.bat auto ........ para el Programador de tareas (Neon, sin pausas)
rem =====================================================================
setlocal EnableDelayedExpansion
cd /d "%~dp0"
chcp 65001 >nul

rem ----- Configuracion -----
set "PSQL=C:\Program Files\PostgreSQL\16\bin\psql.exe"
rem Neon (base oficial en la nube). El servidor no es secreto; la contrasena va en pgpass.conf
set "NEON_HOST=ep-orange-mode-b7dfqolw.c-13.us-east-1.aws.neon.tech"
set "NEON_DB=neondb"
set "NEON_USER=neondb_owner"
set "PGCLIENTENCODING=UTF8"
rem Las contrasenas se toman de %APPDATA%\postgresql\pgpass.conf (ver LEEME)

rem ----- Elegir la base -----
set "MODO="
set "OPCION=%~1"
if /i "%OPCION%"=="auto" (
  set "MODO=auto"
  set "OPCION=neon"
)
if not "%OPCION%"=="" goto con_opcion
echo  A que base quieres cargar?
echo    1. Neon        - OFICIAL, en la nube
echo    2. qa_pruebas  - laboratorio en este PC
choice /c 12 /n /m "  Escribe 1 o 2: "
if errorlevel 2 (set "OPCION=qa_pruebas") else (set "OPCION=neon")

:con_opcion
if /i "%OPCION%"=="neon"       goto destino_neon
if /i "%OPCION%"=="qa_pruebas" goto destino_pruebas
echo  Opcion no reconocida: %OPCION%   Usa neon, qa_pruebas o auto.
goto fin

:destino_neon
set "PGHOST=%NEON_HOST%"
set "PGDATABASE=%NEON_DB%"
set "PGUSER=%NEON_USER%"
set "PGSSLMODE=require"
set "NOMBRE=neon"
goto destino_listo
:destino_pruebas
set "PGHOST=127.0.0.1"
set "PGDATABASE=qa_pruebas"
set "PGUSER=postgres"
set "NOMBRE=qa_pruebas"

:destino_listo
echo.
echo  Base de destino: %NOMBRE%  [%PGHOST%]
echo.

for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd_HHmm"') do set "SELLO=%%i"

if not exist "entrada\*.csv" (
  echo No hay archivos CSV en la carpeta "entrada".
  goto fin
)
if not exist procesados mkdir procesados

rem ----- Detectar que archivos llegaron -----
set "VARS="
for %%T in (vendedores productos tiempos_fabricacion precios clientes facturas pedidos inventario cartera cotizaciones) do (
  if exist "entrada\%%T.csv" (
    set "VARS=!VARS! -v hay_%%T=on"
    echo   Encontrado: %%T.csv
  ) else (
    set "VARS=!VARS! -v hay_%%T=off"
  )
)
echo.

rem Formato de facturas: trae las columnas nuevas (Vendedor, Fecha vencimiento, Factura referencia)?
set "FV2=off"
if exist "entrada\facturas.csv" (
  findstr /n /r /c:"Factura referencia" "entrada\facturas.csv" | findstr /b "1:" >nul && set "FV2=on"
)
set "VARS=!VARS! -v facturas_v2=!FV2!"

rem ----- Cargar -----
"%PSQL%" !VARS! -v reporte=procesados/errores_%NOMBRE%_%SELLO%.csv -f importar.sql
if errorlevel 1 (
  echo.
  echo *** LA CARGA FALLO. La base %NOMBRE% NO se modifico. Los archivos siguen en "entrada". ***
  echo     Revisa el mensaje de error de arriba.
  goto fin
)

rem ----- Archivar los CSV procesados -----
set "DESTINO=procesados\%SELLO%_%NOMBRE%"
mkdir "%DESTINO%" 2>nul
move /y "entrada\*.csv" "%DESTINO%\" >nul
echo.
echo Carga terminada en %NOMBRE%. Archivos movidos a %DESTINO%

:fin
if /i not "%MODO%"=="auto" pause
endlocal
