-- ═══════════════════════════════════════════════════════════════════════════
-- 011 — Corioniciade trigemelar: aceita Di/Tri e Mono/Tri, não só Tri/Tri
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Por quê: a migração 005 abriu gestacoes.tipo_gestacao para 'trigemelar' e
-- gestacoes.corionicidade para 'tricorionica_triamniotica', mas o select de
-- corionicidade no cadastro (index.html, #g-corionicidade) sempre ofereceu
-- três opções pra trigemelar — Tricoriônica/Triamniótica, Dicoriônica/
-- Triamniótica e Monocoriônica/Triamniótica —, não só a primeira. O check
-- da 005 ficou mais estreito que o próprio formulário: escolher qualquer uma
-- das duas últimas opções faz o insert da gestação falhar com
-- "violates check constraint gestacoes_corionicidade_check".
--
-- Roda junto com (ou depois d)a 005 — se a 005 ainda não rodou nesse banco,
-- rode ela primeiro (ou direto esta, que já recria o check com o conjunto
-- completo, então serve mesmo partindo do check antigo da 002).
--
-- Como rodar: SQL Editor do Supabase → cole isto → Run. Seguro rodar mais de
-- uma vez.

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
      and c.conrelid = 'public.gestacoes'::regclass
      and a.attname = 'corionicidade'
      and array_length(c.conkey, 1) = 1
  loop
    execute format('alter table %s drop constraint %I', r.tabela, r.nome);
  end loop;
end $$;

alter table public.gestacoes
  add constraint gestacoes_corionicidade_check
  check (corionicidade in (
    'dicorionica_diamniotica',
    'monocorionica_diamniotica',
    'monocorionica_monoamniotica',
    'tricorionica_triamniotica',
    'dicorionica_triamniotica',
    'monocorionica_triamniotica'
  ));

-- confere
select conrelid::regclass as tabela,
       conname            as constraint,
       pg_get_constraintdef(oid) as definicao
from pg_constraint
where conname = 'gestacoes_corionicidade_check';
