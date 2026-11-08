// Copia la librería de Supabase dentro de la app (así no depende de internet para cargarla)
const fs = require("fs");
fs.copyFileSync("node_modules/@supabase/supabase-js/dist/umd/supabase.js", "www/supabase.js");
