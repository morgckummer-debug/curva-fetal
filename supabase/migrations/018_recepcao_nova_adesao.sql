-- 018 — "Nova adesão" na tela da recepção: cria paciente + gestação com acompanhamento
-- ANTES do primeiro exame, sem a recepção precisar do app inteiro.
--
-- Regras:
--  * CPF sempre no formato canônico 000.000.000-00 (mesmo contrato do editor de laudos).
--  * Se já existe paciente com esse CPF (fora da lixeira), reaproveita — nunca duplica
--    (unique parcial da migração 004).
--  * Se a paciente já tem gestação ativa, só marca a modalidade nela; se essa gestação já
--    tem outra modalidade, recusa (alterar é com a médica, no app).
--  * Sem id explícito: a identity gera (faixa a partir de 1.000.000, migração 004).
--  * DUM é opcional: sem ela, as janelas só aparecem depois do primeiro exame.
-- Serve para a secretária e para a própria médica (mesmo padrão da 017).

create or replace function public.recepcao_nova_adesao(
  p_nome text, p_cpf text, p_modalidade text, p_dum date default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono   uuid;
  v_digits text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  v_cpf    text;
  v_pac    bigint;
  v_ges    bigint;
  v_atual  text;
  v_tipo   text;
begin
  select dono_id into v_dono from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;
  if length(v_digits) <> 11 then
    raise exception 'CPF deve ter 11 dígitos';
  end if;
  if p_modalidade not in ('essencial','premium','gemelar_essencial','gemelar_dc') then
    raise exception 'modalidade inválida';
  end if;
  if btrim(coalesce(p_nome, '')) = '' then
    raise exception 'informe o nome';
  end if;
  v_cpf  := substr(v_digits,1,3) || '.' || substr(v_digits,4,3) || '.' || substr(v_digits,7,3) || '-' || substr(v_digits,10,2);
  v_tipo := case when p_modalidade like 'gemelar%' then 'gemelar' else 'unica' end;

  select id into v_pac from public.patients
   where user_id = v_dono and excluido_em is null and cpf in (v_cpf, v_digits)
   order by id limit 1;
  if v_pac is null then
    insert into public.patients (user_id, cpf, nome) values (v_dono, v_cpf, btrim(p_nome))
    returning id into v_pac;
  end if;

  select id, acompanhamento into v_ges, v_atual from public.gestacoes
   where user_id = v_dono and paciente_id = v_pac and excluido_em is null and status = 'ativa'
   order by id desc limit 1;

  if v_ges is null then
    insert into public.gestacoes (user_id, paciente_id, dum, dpp, tipo_gestacao, acompanhamento)
    values (v_dono, v_pac, p_dum, case when p_dum is not null then p_dum + 280 end, v_tipo, p_modalidade)
    returning id into v_ges;
  elsif v_atual is null then
    update public.gestacoes
       set acompanhamento = p_modalidade,
           dum = coalesce(dum, p_dum),
           dpp = coalesce(dpp, case when p_dum is not null then p_dum + 280 end)
     where id = v_ges;
  elsif v_atual <> p_modalidade then
    raise exception 'esta paciente já tem o acompanhamento % — alterar é com a médica', v_atual;
  end if;
  return v_ges;
end;
$$;

revoke all on function public.recepcao_nova_adesao(text, text, text, date) from public, anon;
grant execute on function public.recepcao_nova_adesao(text, text, text, date) to authenticated;
