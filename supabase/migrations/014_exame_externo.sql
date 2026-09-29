-- ═══════════════════════════════════════════════════════════════════════════
-- 014 — Exame externo (feito em outro serviço) + peso estimado informado
-- ═══════════════════════════════════════════════════════════════════════════
--
-- "Entrada rápida" de exames trazidos pela paciente: laudos de outro serviço
-- entram no histórico para a revisão pré-exame e para as curvas de tendência.
--
--   externo            true quando o exame não foi feito na clínica. Default
--                      false: os exames existentes e os do editor de laudos
--                      (que não conhece a coluna) continuam "da casa".
--   servico_externo    nome do serviço/profissional, texto livre, opcional.
--   efw                peso fetal estimado (g) digitado do laudo externo. Quando
--                      preenchido, o app calcula o percentil a partir dele em
--                      vez de recalcular por Hadlock com as medidas (o código já
--                      lia `e.efw ?? calcEFW(...)`; só faltava a coluna). Nulo
--                      nos exames da clínica — o peso continua calculado.
--   impressao_externa  conclusão do laudo externo, texto livre, opcional —
--                      para não perder o que o outro colega concluiu.
--
-- Tudo nullable/com default: nenhuma linha existente muda e nenhuma escrita
-- antiga (editor de laudos) quebra. Sem CHECK, no espírito das colunas de risco.

alter table public.exams
  add column if not exists externo boolean not null default false,
  add column if not exists servico_externo text,
  add column if not exists efw numeric,
  add column if not exists impressao_externa text;
