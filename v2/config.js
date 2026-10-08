// Configuración de MisFinanzas v2.
// Estos dos valores se copian desde Supabase > Project Settings > API:
//   SUPABASE_URL      -> "Project URL"
//   SUPABASE_ANON_KEY -> clave "anon public" (o "publishable"). Es pública por diseño:
//                        la seguridad la da el RLS de la base. NUNCA pegues acá la clave "service_role".
window.MF_CONFIG = {
  SUPABASE_URL: 'https://vilfohgqmudrvlpgkygv.supabase.co',
  SUPABASE_ANON_KEY: 'PEGAR-ACA-LA-CLAVE-PUBLISHABLE-O-ANON'
};