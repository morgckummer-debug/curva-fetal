-- ═══════════════════════════════════════════════════════════════════════════
-- 010 — Cerclagem realizada e progesterona vaginal em uso
-- ═══════════════════════════════════════════════════════════════════════════
--
-- avaliarRiscoColoCurto (index.html) sugere cerclagem e progesterona vaginal
-- a partir só da medida do colo — sem saber se a gestante já fez cerclagem ou
-- já está em uso de progesterona, o alerta repetia a sugestão mesmo quando a
-- conduta já tinha sido tomada, e recomendava "avaliar cerclagem" mesmo com o
-- feto viável (colo curto detectado no 3º trimestre), quando o benefício
-- documentado do procedimento é do 2º trimestre.
--
-- Esta migração adiciona três campos estruturados na gestação, todos opt-in
-- (default false/null — não presume ausência, só não bloqueia quem não
-- preencher), no mesmo espírito da 009 (ppt_espontaneo_previo).

alter table public.gestacoes
  add column if not exists progesterona_vaginal_em_uso boolean not null default false,
  add column if not exists cerclagem_realizada boolean not null default false,
  add column if not exists cerclagem_ig_semanas smallint;
