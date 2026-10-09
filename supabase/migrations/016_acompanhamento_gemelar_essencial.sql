-- 016 — Segunda modalidade gemelar: Gemelar Essencial (calendário do Essencial).
-- 'gemelar_dc' continua sendo o Gemelar Premium (nome interno antigo, sem renomear linhas).
alter table public.gestacoes drop constraint if exists gestacoes_acompanhamento_check;
alter table public.gestacoes add constraint gestacoes_acompanhamento_check
  check (acompanhamento in ('essencial','premium','gemelar_dc','gemelar_essencial'));
