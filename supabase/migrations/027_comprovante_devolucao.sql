drop function if exists public.recepcao_devolucao(bigint, text, text, numeric, date, text, text);

create or replace function public.recepcao_devolucao(
  p_gestacao_id bigint, p_status text, p_opcao text, p_valor numeric, p_data date, p_forma text, p_obs text,
  p_comprovante jsonb default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid;
  v_nome text;
  v_comp jsonb;
begin
  select dono_id, nome into v_dono, v_nome from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then
    v_dono := auth.uid();
    v_nome := 'Dra. Morgana';
  end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;
  if p_status not in ('pendente', 'escolha', 'devolvido', 'credito', 'nada') then
    raise exception 'status inválido';
  end if;
  if p_comprovante is not null and (
       p_comprovante->>'path' is null
       or p_comprovante->>'path' not like v_dono::text || '/' || p_gestacao_id::text || '/%') then
    raise exception 'caminho do comprovante inválido';
  end if;
  select encerramento->'devolucao'->'comprovante' into v_comp
    from public.pagamentos_acompanhamento
   where gestacao_id = p_gestacao_id and user_id = v_dono and encerramento is not null;
  if not found then
    raise exception 'encerramento não registrado';
  end if;
  -- sem comprovante novo, mantém o que já estava anexado
  v_comp := coalesce(p_comprovante, v_comp);
  update public.pagamentos_acompanhamento
     set encerramento = jsonb_set(encerramento, '{devolucao}', jsonb_strip_nulls(jsonb_build_object(
           'status', p_status, 'opcao', nullif(p_opcao, ''), 'valor', p_valor, 'data', p_data,
           'forma', nullif(left(coalesce(p_forma, ''), 40), ''), 'obs', left(coalesce(p_obs, ''), 500),
           'comprovante', v_comp,
           'por', coalesce(v_nome, ''), 'em', now()))),
         atualizado_por = coalesce(v_nome, ''), atualizado_em = now()
   where gestacao_id = p_gestacao_id and user_id = v_dono;
end;
$$;

revoke all on function public.recepcao_devolucao(bigint, text, text, numeric, date, text, text, jsonb) from public, anon;
grant execute on function public.recepcao_devolucao(bigint, text, text, numeric, date, text, text, jsonb) to authenticated;

-- 027 — Comprovante da DEVOLUÇÃO (Pix/estorno da clínica para a paciente), separado dos comprovantes
-- do pagamento (023). O arquivo vai para o bucket `comprovantes` em {dono}/{gestacao}/devolucao-….
-- A referência fica em encerramento.devolucao.comprovante {path,nome,tipo}. Chamar a função sem
-- comprovante mantém o que já estava anexado.
