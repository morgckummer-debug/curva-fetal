-- 019 — "Nova adesão" aceita a idade gestacional de três jeitos: DUM, primeiro
-- ultrassom (data + IG naquele dia) ou IG de hoje (a recepção calcula no CalcMK).
-- IG por ultrassom/hoje grava ig_base_* (ig_base_tipo = 'US'), que é o que o
-- calcIgDays do app já prefere à DUM. dpp = ig_base_data + (280 - dias).
-- Troca a assinatura de 4 para 6 argumentos (a antiga é removida).

drop function if exists public.recepcao_nova_adesao(text, text, text, date);

create or replace function public.recepcao_nova_adesao(
  p_nome text, p_cpf text, p_modalidade text, p_dum date default null,
  p_ig_base_data date default null, p_ig_base_dias integer default null
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
  v_dum    date;
  v_dpp    date;
  v_bdata  date;
  v_bval   integer;
  v_btipo  text;
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
  if p_ig_base_data is not null and (p_ig_base_dias is null or p_ig_base_dias < 1 or p_ig_base_dias > 300) then
    raise exception 'idade gestacional inválida';
  end if;
  v_cpf  := substr(v_digits,1,3) || '.' || substr(v_digits,4,3) || '.' || substr(v_digits,7,3) || '-' || substr(v_digits,10,2);
  v_tipo := case when p_modalidade like 'gemelar%' then 'gemelar' else 'unica' end;

  -- Base de datação: ultrassom/IG de hoje tem prioridade; senão DUM.
  if p_ig_base_data is not null then
    v_bdata := p_ig_base_data; v_bval := p_ig_base_dias; v_btipo := 'US';
    v_dpp := p_ig_base_data + (280 - p_ig_base_dias);
  elsif p_dum is not null then
    v_dum := p_dum; v_dpp := p_dum + 280;
  end if;

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
    insert into public.gestacoes (user_id, paciente_id, dum, dpp, ig_base_data, ig_base_valor, ig_base_tipo,
                                  tipo_gestacao, acompanhamento)
    values (v_dono, v_pac, v_dum, v_dpp, v_bdata, v_bval, v_btipo, v_tipo, p_modalidade)
    returning id into v_ges;
  elsif v_atual is null then
    -- Gestação já existente: só preenche datação se ela ainda não tem nenhuma.
    update public.gestacoes
       set acompanhamento = p_modalidade,
           dum = coalesce(dum, case when ig_base_data is null then v_dum end),
           dpp = coalesce(dpp, v_dpp),
           ig_base_data  = case when dum is null and ig_base_data is null then v_bdata else ig_base_data end,
           ig_base_valor = case when dum is null and ig_base_data is null then v_bval  else ig_base_valor end,
           ig_base_tipo  = case when dum is null and ig_base_data is null then v_btipo else ig_base_tipo end
     where id = v_ges;
  elsif v_atual <> p_modalidade then
    raise exception 'esta paciente já tem o acompanhamento % — alterar é com a médica', v_atual;
  end if;
  return v_ges;
end;
$$;

revoke all on function public.recepcao_nova_adesao(text, text, text, date, date, integer) from public, anon;
grant execute on function public.recepcao_nova_adesao(text, text, text, date, date, integer) to authenticated;
