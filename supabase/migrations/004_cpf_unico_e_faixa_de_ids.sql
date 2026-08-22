-- ═══════════════════════════════════════════════════════════════════════
-- Migração 004 — fecha as duas brechas que deixavam os dois apps brigarem
-- pela mesma tabela `patients`
--
-- Quem escreve aqui: o app de curvas (repo curva-fetal) e o editor de laudos
-- (repo laudos-dramorgana). Duas brechas deixavam os dois se atrapalharem:
--
--   1. Não havia unique em `cpf`. A mesma paciente podia existir em duas
--      linhas, cada app enxergando a sua, sem nenhum erro — foi o que
--      escondeu o bug de formato do CPF (migração 003) por tanto tempo.
--
--   2. Dois geradores de id para a mesma tabela. O app de curvas escolhe o
--      id (maior id + 1) e grava por upsert; o editor insere sem id e deixa
--      a identity do Postgres gerar. Como todo id vindo do app é explícito,
--      a identity nunca avançou e continua apontando para números que o app
--      já usou: o próximo insert do editor colide com uma linha existente.
--      No sentido inverso é pior — o upsert do app reescreve as tabelas
--      inteiras, então uma linha do editor com id repetido seria sobrescrita
--      em silêncio.
--
-- Como rodar: SQL Editor do Supabase → cole isto → Run. Seguro rodar mais de
-- uma vez. RODE A 003 ANTES: o passo 1 falha de propósito se ainda houver CPF
-- duplicado ou fora do formato.
-- ═══════════════════════════════════════════════════════════════════════

-- ═══ PASSO 1 — trava de segurança: exige a 003 já aplicada ═══
-- Não altera nada; só interrompe a migração com uma mensagem clara se o
-- terreno ainda não estiver limpo (criar o índice do passo 2 falharia com
-- "could not create unique index", bem menos explicativo).
do $$
declare
  n_duplicados int;
  n_fora_formato int;
begin
  select count(*) into n_duplicados from (
    select 1
    from public.patients
    where excluido_em is null
    group by user_id, regexp_replace(cpf, '\D', '', 'g')
    having count(*) > 1
  ) d;

  select count(*) into n_fora_formato
  from public.patients
  where cpf !~ '^\d{3}\.\d{3}\.\d{3}-\d{2}$';

  if n_duplicados > 0 then
    raise exception 'Ainda há % CPF(s) em mais de uma linha. Rode a migração 003 (passos 2 e 3) antes desta.', n_duplicados;
  end if;

  if n_fora_formato > 0 then
    raise exception 'Ainda há % linha(s) com CPF fora do formato 000.000.000-00. Rode a migração 003 (passo 4) antes desta.', n_fora_formato;
  end if;
end $$;

-- ═══ PASSO 2 — uma paciente por CPF ═══
-- Índice parcial: só vale para quem não está na lixeira. Assim uma paciente
-- excluída não impede o CPF dela de ser cadastrado de novo, que é como o app
-- já trata o soft-delete em toda leitura.
create unique index if not exists patients_cpf_unico_idx
  on public.patients(user_id, cpf)
  where excluido_em is null;

-- ═══ PASSO 3 — separa as faixas de id dos dois geradores ═══
-- A identity passa a entregar ids a partir de 1.000.000; o app de curvas só
-- conta os ids abaixo disso ao escolher o próximo (_proximoIdLocal, no
-- index.html). As duas faixas deixam de se cruzar.
--
-- greatest(...) protege o caso de já existir id igual ou acima da fronteira:
-- a sequência nunca anda para trás.
select setval(
  pg_get_serial_sequence('public.patients', 'id'),
  greatest(1000000, coalesce((select max(id) from public.patients), 0) + 1),
  false
);

select setval(
  pg_get_serial_sequence('public.gestacoes', 'id'),
  greatest(1000000, coalesce((select max(id) from public.gestacoes), 0) + 1),
  false
);

select setval(
  pg_get_serial_sequence('public.exams', 'id'),
  greatest(1000000, coalesce((select max(id) from public.exams), 0) + 1),
  false
);

-- ═══ PASSO 4 — confere ═══
-- Deve mostrar as três sequências em 1000000 (ou acima, se já havia id maior).
-- (pg_sequences.last_value vem NULL enquanto is_called = false, então lê-se a
-- própria sequência.)
select 'patients'  as tabela, last_value, is_called from public.patients_id_seq
union all
select 'gestacoes', last_value, is_called from public.gestacoes_id_seq
union all
select 'exams',     last_value, is_called from public.exams_id_seq;
