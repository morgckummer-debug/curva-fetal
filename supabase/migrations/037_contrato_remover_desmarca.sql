-- 037: remover o contrato ASSINADO desmarca "contrato assinado" quando não sobra outro.
-- Antes a 026 só tirava o item da lista; o flag contrato_assinado continuava true, a ficha
-- seguia "Assinado ✓" e o botão "Gerar contrato" não voltava. Remover um contrato GERADO não
-- mexe no flag (ele pode ter sido marcado à mão, de um contrato assinado em papel).
create or replace function public.recepcao_contrato_remover(p_gestacao_id bigint, p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid;
  v_era_assinado boolean;
begin
  select dono_id into v_dono from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;
  select exists (select 1 from jsonb_array_elements(coalesce(contratos, '[]'::jsonb)) x
                  where x->>'path' = p_path and x->>'kind' = 'assinado')
    into v_era_assinado
    from public.pagamentos_acompanhamento
   where gestacao_id = p_gestacao_id and user_id = v_dono;
  update public.pagamentos_acompanhamento
     set contratos = coalesce((
           select jsonb_agg(x) from jsonb_array_elements(contratos) x where x->>'path' <> p_path
         ), '[]'::jsonb)
   where gestacao_id = p_gestacao_id and user_id = v_dono;
  if coalesce(v_era_assinado, false) then
    update public.pagamentos_acompanhamento
       set contrato_assinado = exists (select 1 from jsonb_array_elements(contratos) x where x->>'kind' = 'assinado')
     where gestacao_id = p_gestacao_id and user_id = v_dono;
  end if;
end;
$$;
