"""
Genera la línea de un usuario para la sección [usuarios] de secrets.toml.
La contraseña NO se guarda: solo un "hash" (huella) del que no se puede recuperar.

Uso:  python generar_clave.py
"""
import getpass
import hashlib
import os

usuario = input("Usuario (sin espacios, ej. edward): ").strip().lower()
c1 = getpass.getpass("Contraseña (no se ve al escribir): ")
c2 = getpass.getpass("Repite la contraseña: ")
if not usuario or not c1:
    raise SystemExit("Usuario y contraseña son obligatorios.")
if c1 != c2:
    raise SystemExit("Las contraseñas no coinciden.")
if len(c1) < 8:
    raise SystemExit("Usa al menos 8 caracteres.")
sal = os.urandom(16)
it = 200_000
h = hashlib.pbkdf2_hmac("sha256", c1.encode(), sal, it).hex()
print("\nCopia esta línea debajo de [usuarios] en los secretos de la app:\n")
print(f'{usuario} = "pbkdf2${it}${sal.hex()}${h}"')
