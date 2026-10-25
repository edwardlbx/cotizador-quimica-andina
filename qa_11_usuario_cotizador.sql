/* =====================================================================
   QUÍMICA ANDINA S.A.S. (ficticia) — Script 11: USUARIO DE LA APP
   ---------------------------------------------------------------------
   Crea el usuario "cotizador" con el que se conecta la app publicada.
   Principio de mínimo privilegio: puede LEER todo el esquema qa y solo
   ESCRIBIR propuestas (PP). No puede cargar, borrar ni cambiar nada más:
   si alguien obtiene su contraseña, no puede dañar la base.

   Uso (desde la terminal, la contraseña llega en la variable "clave"):
     psql -d <base> -v clave="..." -f qa_11_usuario_cotizador.sql
   Se puede ejecutar varias veces (actualiza la contraseña y los permisos).
   ===================================================================== */
\set ON_ERROR_STOP on

SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cotizador') AS crear \gset
\if :crear
CREATE ROLE cotizador LOGIN PASSWORD :'clave';
\else
ALTER ROLE cotizador LOGIN PASSWORD :'clave';
\endif

-- La app trabaja en hora de Colombia, igual que la base
ALTER ROLE cotizador SET timezone TO 'America/Bogota';

-- Leer: todo el esquema qa (tablas y vistas)
GRANT USAGE ON SCHEMA qa TO cotizador;
GRANT SELECT ON ALL TABLES IN SCHEMA qa TO cotizador;
ALTER DEFAULT PRIVILEGES IN SCHEMA qa GRANT SELECT ON TABLES TO cotizador;   -- vistas futuras

-- Escribir: solo lo que hace el cotizador (registrar y enlazar propuestas)
GRANT INSERT, UPDATE ON qa.propuestas, qa.propuestas_detalle, qa.consecutivos TO cotizador;

-- Nada en el esquema de carga (stg) ni permisos de borrado
REVOKE ALL ON SCHEMA stg FROM cotizador;

SELECT 'Usuario cotizador listo' AS resultado,
       has_table_privilege('cotizador', 'qa.clientes',  'SELECT') AS lee_clientes,
       has_table_privilege('cotizador', 'qa.propuestas', 'INSERT') AS crea_propuestas,
       has_table_privilege('cotizador', 'qa.facturas',  'DELETE') AS borra_facturas,
       has_table_privilege('cotizador', 'qa.clientes',  'UPDATE') AS modifica_clientes;
