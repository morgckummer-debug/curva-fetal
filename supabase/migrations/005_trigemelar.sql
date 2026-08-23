-- ═══════════════════════════════════════════════════════════════════════
-- Migração 005 — gestação trigemelar (Feto C)
--
-- Por quê: o editor de laudos (repo laudos-dramorgana) atende até três fetos
-- no laudo de 2º/3º trimestre, mas este banco só aceitava o par A/B —
-- `exams.feto` tinha check (feto in ('A','B')) e `gestacoes.tipo_gestacao`
-- só conhecia 'unica' e 'gemelar'. Enquanto isso, o laudo mandava o terceiro
-- feto como 'B': passava no check e virava duas medidas diferentes sob o
-- mesmo rótulo dentro do prontuário. O envio ficou travado até esta migração.
--
-- O que muda:
--   - exams.feto passa a aceitar 'C'.
--   - gestacoes.tipo_gestacao passa a aceitar 'trigemelar'.
--   - gestacoes.corionicidade passa a aceitar 'tricorionica_triamniotica',
--     que é o que o laudo já oferece no select e que hoje faria o insert da
--     gestação falhar.
--
-- Nada é reescrito: a migração só afrouxa os checks, então gestação única e
-- gemelar continuam exatamente como estavam.
--
-- Como rodar: SQL Editor do Supabase → cole isto → Run. Seguro rodar mais de
-- uma vez. RODE ANTES de publicar o código novo dos dois apps — o app que
-- manda 'C' num banco sem esta migração leva erro de check no insert.
-- ═══════════════════════════════════════════════════════════════════════

-- ═══ PASSO 1 — troca os checks pelos novos ═══
-- Os checks antigos nasceram junto com as colunas (migração 002), então o
-- nome deles foi escolhido pelo Postgres. Em vez de adivinhar o nome, o bloco
-- procura qualquer check daquela coluna e derruba o que encontrar — assim a
-- migração funciona tanto no banco criado pelo schema.sql quanto no que foi
-- crescendo pelas migrações.
do $$
declare
  r record;
begin
  for r in
    select c.conrelid::regclass as tabela, c.conname as nome
    from pg_constraint c
    join pg_attribute a
      on a.attrelid = c.conrelid
     and a.attnum   = any(c.conkey)
    where c.contype = 'c'
      and c.conrelid in ('public.exams'::regclass, 'public.gestacoes'::regclass)
      and a.attname in ('feto', 'tipo_gestacao', 'corionicidade')
      and array_length(c.conkey, 1) = 1
  loop
    execute format('alter table %s drop constraint %I', r.tabela, r.nome);
  end loop;
end $$;

alter table public.exams
  add constraint exams_feto_check
  check (feto in ('A','B','C'));

alter table public.gestacoes
  add constraint gestacoes_tipo_gestacao_check
  check (tipo_gestacao in ('unica','gemelar','trigemelar'));

alter table public.gestacoes
  add constraint gestacoes_corionicidade_check
  check (corionicidade in (
    'dicorionica_diamniotica',
    'monocorionica_diamniotica',
    'monocorionica_monoamniotica',
    'tricorionica_triamniotica'
  ));

-- ═══ PASSO 2 — confere ═══
-- Devem aparecer os três checks acima, já com os valores novos.
select conrelid::regclass as tabela,
       conname            as constraint,
       pg_get_constraintdef(oid) as definicao
from pg_constraint
where conname in ('exams_feto_check',
                  'gestacoes_tipo_gestacao_check',
                  'gestacoes_corionicidade_check')
order by 1, 2;
