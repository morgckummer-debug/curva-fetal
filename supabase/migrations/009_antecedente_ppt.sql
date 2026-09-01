-- ═══════════════════════════════════════════════════════════════════════════
-- 009 — Antecedente de parto prematuro espontâneo
-- ═══════════════════════════════════════════════════════════════════════════
--
-- O alerta de colo curto (avaliarRiscoColoCurto, index.html) segue a escada
-- da ISUOG 2022 (colo curto <25mm, considerar cerclagem <10mm) e da FMF
-- (corte de 15mm do estudo fundador da progesterona vaginal, Fonseca et al.
-- 2007). Em várias dessas faixas a indicação de cerclagem muda bastante
-- conforme a gestante já teve ou não parto prematuro espontâneo antes — e até
-- aqui o único lugar pra registrar isso era o campo de texto livre
-- "antecedentes_obstetricos" (ex: "HAS, DM, gemelar anterior..."), que o app
-- não tem como interpretar de forma confiável.
--
-- Esta migração adiciona um campo estruturado booleano na gestação, opt-in
-- (default false — não presume ausência de antecedente, só não bloqueia
-- quem não preencher).

alter table public.gestacoes
  add column if not exists ppt_espontaneo_previo boolean not null default false;
