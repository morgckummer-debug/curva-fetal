-- 020: a recepção pode mandar para a lixeira um cadastro feito por engano.
-- Só vale para gestação SEM nenhum exame: quem já tem exame só a médica remove (pela ficha).
-- É exclusão lógica (excluido_em), a mesma da lixeira do app: dá para recuperar.
create or replace function public.recepcao_excluir_cadastro(p_gestacao_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid;
  v_pac bigint;
begin
  select dono_id into v_dono from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;

  select paciente_id into v_pac from public.gestacoes
   where id = p_gestacao_id and user_id = v_dono and excluido_em is null;
  if v_pac is null then
    raise exception 'cadastro não encontrado';
  end if;
  if exists (select 1 from public.exams where gestacao_id = p_gestacao_id and user_id = v_dono and excluido_em is null) then
    raise exception 'esta paciente já tem exame registrado; peça para a Dra. Morgana excluir';
  end if;

  update public.gestacoes set excluido_em = now() where id = p_gestacao_id;
  -- a paciente também sai, se não tiver outra gestação ativa
  if not exists (select 1 from public.gestacoes where paciente_id = v_pac and user_id = v_dono and excluido_em is null) then
    update public.patients set excluido_em = now() where id = v_pac and user_id = v_dono;
  end if;
end;
$$;

revoke all on function public.recepcao_excluir_cadastro(bigint) from public, anon;
grant execute on function public.recepcao_excluir_cadastro(bigint) to authenticated;
