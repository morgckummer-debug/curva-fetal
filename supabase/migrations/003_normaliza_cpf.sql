-- 003 — Normaliza o CPF para o formato pontuado (000.000.000-00)
--
-- Contexto: o editor de laudos (repo laudos-dramorgana) grava a paciente direto
-- nesta tabela. Até 2026-08-22 o laudo obstétrico de 2º/3º trimestre gravava o
-- CPF só com os 11 dígitos, enquanto o app de curvas sempre gravou pontuado.
-- Como não há unique em patients.cpf, o mesmo CPF virava duas pacientes e o
-- exame enviado pelo laudo ficava numa gestação invisível no prontuário.
--
-- Os dois apps já foram corrigidos; esta migração conserta as linhas antigas.
-- RODE COM CALMA, na ordem, conferindo o resultado de cada passo.
-- Faça o backup antes (botão "⬇ Backup" no app de curvas).

-- ═══ PASSO 1 — diagnóstico: quais linhas estão fora do formato ═══
select id, cpf, nome, created_at
from public.patients
where cpf !~ '^\d{3}\.\d{3}\.\d{3}-\d{2}$'
order by id;

-- ═══ PASSO 2 — diagnóstico: a mesma pessoa está em duas linhas? ═══
select regexp_replace(cpf, '\D', '', 'g') as digitos,
       count(*)                           as linhas,
       array_agg(id   order by id)        as ids,
       array_agg(nome order by id)        as nomes
from public.patients
where excluido_em is null
group by 1
having count(*) > 1;

-- ═══ PASSO 3 — SÓ SE O PASSO 2 VOLTOU LINHAS: funde as duplicatas ═══
-- Mantém a linha de menor id (a mais antiga, normalmente a cadastrada no app de
-- curvas) e move para ela as gestações da duplicata. Rode os dois comandos na
-- ordem: apagar antes de mover levaria junto as gestações e exames por cascade.
--
-- begin;
--
-- with grp as (
--   select id,
--          min(id) over (partition by regexp_replace(cpf, '\D', '', 'g')) as manter
--   from public.patients
--   where excluido_em is null
-- )
-- update public.gestacoes g
-- set paciente_id = grp.manter
-- from grp
-- where g.paciente_id = grp.id and grp.id <> grp.manter;
--
-- with grp as (
--   select id,
--          min(id) over (partition by regexp_replace(cpf, '\D', '', 'g')) as manter
--   from public.patients
--   where excluido_em is null
-- )
-- delete from public.patients p
-- using grp
-- where p.id = grp.id and grp.id <> grp.manter;
--
-- commit;

-- ═══ PASSO 4 — normaliza o formato das linhas restantes ═══
update public.patients
set cpf = regexp_replace(regexp_replace(cpf, '\D', '', 'g'),
                         '^(\d{3})(\d{3})(\d{3})(\d{2})$', '\1.\2.\3-\4')
where regexp_replace(cpf, '\D', '', 'g') ~ '^\d{11}$'
  and cpf !~ '^\d{3}\.\d{3}\.\d{3}-\d{2}$';

-- ═══ PASSO 5 — confere: deve voltar zero linhas ═══
select id, cpf, nome
from public.patients
where cpf !~ '^\d{3}\.\d{3}\.\d{3}-\d{2}$';
