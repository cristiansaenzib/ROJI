# Tienda Pedidos – instaladores

## 1. Base de datos (Supabase)
- Proyecto nuevo: ejecuta `sql/1-base.sql` y luego `sql/2-clientes-apartados.sql` (SQL Editor > Run).
- Si ya ejecutaste el primero: ejecuta solo el 2.
- Authentication > Users: crea tu usuario administrador. Desactiva el registro de nuevos usuarios.
- Project Settings > API: copia la URL y la clave `anon public` en las dos primeras líneas del script de `www/index.html` (`SB_URL` y `SB_KEY`).

## 2. Generar los instaladores SIN instalar nada (recomendado)
1. Crea un repositorio privado en github.com y sube esta carpeta completa.
2. Entra a la pestaña **Actions > Construir instaladores > Run workflow**.
3. En ~10 minutos descargas: `instalador-windows` (.exe) y `apk-android` (.apk).
4. Android: copia el .apk a la tablet y ábrelo (permite "instalar apps desconocidas").

## 3. Generarlos en tu computador (opcional)
- Windows: instala Node.js 20, luego `npm install` y `npm run build:win` (sale en `dist/`).
- Android: además Android Studio; `npx cap add android`, `npx cap sync android` y `npx cap open android` > Build > Build APK.
- Probar rápido en el PC: `npm install` y `npm start`.

## Cómo funciona
- Tablet: el cliente escribe su cédula. Si es mayorista/distribuidor, ve sus precios automáticamente; el selector de tipo queda bloqueado. Tras 3 min sin uso se cierra la sesión del cliente y del admin.
- Apartar congela unidades; en Admin > Pedidos se convierte en venta final (resta stock) o se libera.
- Admin con sesión iniciada también ve "Vender ahora" (venta directa) en el pedido.
