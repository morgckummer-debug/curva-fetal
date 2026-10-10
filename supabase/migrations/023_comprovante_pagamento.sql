-- 023 — Comprovante de pagamento (foto pelo celular ou arquivo) na ficha da recepção.
--
-- A lista de comprovantes mora em pagamentos_acompanhamento.comprovantes (jsonb), na mesma tabela
-- da conferência (017/022), e os arquivos num bucket privado `comprovantes`:
--   comprovantes/{dono_id}/{gestacao_id}/{epoch}.{ext}
-- A primeira pasta é sempre o id da MÉDICA (dona dos dados), mesmo quando quem envia é uma
-- secretária: dono_recepcao() resolve isso, e as policies de storage comparam a pasta com ele.
-- Assim a secretária anexa/vê/remove só os comprovantes da médica a quem está ligada.
--
-- Idempotente.

alter table public.pagamentos_acompanhamento
  add column if not exists comprovantes jsonb not null default '[]'::jsonb;

-- Dona dos dados para quem está logado: a médica é ela mesma; a secretária é a médica ligada a ela.
create or replace function public.dono_recepcao()
returns uuid
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((select dono_id from public.recepcao_acessos where user_id = auth.uid()), auth.uid());
$$;
revoke all on function public.dono_recepcao() from public, anon;
grant execute on function public.dono_recepcao() to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('comprovantes', 'comprovantes', false, 10485760, null)
on conflict (id) do update
  set public = excluded.public, file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "comprovantes: lê"    on storage.objects;
drop policy if exists "comprovantes: grava" on storage.objects;
drop policy if exists "comprovantes: apaga" on storage.objects;

create policy "comprovantes: lê"
  on storage.objects for select to authenticated
  using (bucket_id = 'comprovantes' and (storage.foldername(name))[1] = public.dono_recepcao()::text);
create policy "comprovantes: grava"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'comprovantes' and (storage.foldername(name))[1] = public.dono_recepcao()::text);
create policy "comprovantes: apaga"
  on storage.objects for delete to authenticated
  using (bucket_id = 'comprovantes' and (storage.foldername(name))[1] = public.dono_recepcao()::text);

-- Painel: devolve também a lista de comprovantes da conferência.
create or replace function public.painel_recepcao()
returns jsonb
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_dono uuid;
begin
  select dono_id into v_dono from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'gestacao_id',    g.id,
        'nome',           p.nome,
        'cpf',            p.cpf,
        'acompanhamento', g.acompanhamento,
        'tipo_gestacao',  g.tipo_gestacao,
        'dum',            g.dum,
        'ig_base_data',   g.ig_base_data,
        'ig_base_valor',  g.ig_base_valor,
        'pagamento', (
          select jsonb_build_object(
                   'status', pg.status, 'forma', pg.forma, 'parcelas', pg.parcelas,
                   'contrato_assinado', pg.contrato_assinado, 'observacao', pg.observacao,
                   'celular', pg.celular, 'valor_pago', pg.valor_pago, 'comprovantes', pg.comprovantes,
                   'atualizado_por', pg.atualizado_por, 'atualizado_em', pg.atualizado_em)
          from public.pagamentos_acompanhamento pg where pg.gestacao_id = g.id
        ),
        'exames', coalesce((
          select jsonb_agg(
                   jsonb_build_object(
                     'data_exame',     x.data_exame,
                     'ig_dias_manual', x.ig_dias_manual,
                     'extra',          x.extra,
                     'externo',        x.externo
                   ) order by x.data_exame)
          from (
            select e.data_exame,
                   max(e.ig_dias_manual) as ig_dias_manual,
                   bool_or(e.extra)      as extra,
                   bool_or(e.externo)    as externo
            from public.exams e
            where e.gestacao_id = g.id and e.excluido_em is null
            group by e.data_exame
          ) x
        ), '[]'::jsonb)
      ) order by p.nome
    )
    from public.gestacoes g
    join public.patients p on p.id = g.paciente_id
    where g.user_id = v_dono
      and g.excluido_em is null
      and p.excluido_em is null
      and g.status = 'ativa'
      and g.acompanhamento is not null
  ), '[]'::jsonb);
end;
$$;

-- Registra um comprovante já enviado ao Storage.
create or replace function public.recepcao_comprovante_add(p_gestacao_id bigint, p_path text, p_nome text, p_tipo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid;
  v_nome text;
begin
  select dono_id, nome into v_dono, v_nome from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then
    v_dono := auth.uid();
    v_nome := 'Dra. Morgana';
  end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;
  if not exists (select 1 from public.gestacoes where id = p_gestacao_id and user_id = v_dono and excluido_em is null) then
    raise exception 'gestação não encontrada';
  end if;
  if p_path is null or p_path not like v_dono::text || '/' || p_gestacao_id::text || '/%' then
    raise exception 'caminho inválido';
  end if;
  insert into public.pagamentos_acompanhamento (gestacao_id, user_id, comprovantes, atualizado_por, atualizado_em)
  values (p_gestacao_id, v_dono,
          jsonb_build_array(jsonb_build_object('path', p_path, 'nome', left(coalesce(p_nome, ''), 120),
                            'tipo', left(coalesce(p_tipo, ''), 60), 'por', coalesce(v_nome, ''), 'em', now())),
          coalesce(v_nome, ''), now())
  on conflict (gestacao_id) do update set
    comprovantes = pagamentos_acompanhamento.comprovantes ||
      jsonb_build_array(jsonb_build_object('path', p_path, 'nome', left(coalesce(p_nome, ''), 120),
                        'tipo', left(coalesce(p_tipo, ''), 60), 'por', coalesce(v_nome, ''), 'em', now()));
end;
$$;

-- Tira um comprovante da lista (o arquivo é apagado do Storage pelo app).
create or replace function public.recepcao_comprovante_remover(p_gestacao_id bigint, p_path text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono uuid;
begin
  select dono_id into v_dono from public.recepcao_acessos where user_id = auth.uid();
  if v_dono is null then v_dono := auth.uid(); end if;
  if v_dono is null then
    raise exception 'sem acesso' using errcode = '42501';
  end if;
  update public.pagamentos_acompanhamento
     set comprovantes = coalesce((
           select jsonb_agg(x) from jsonb_array_elements(comprovantes) x where x->>'path' <> p_path
         ), '[]'::jsonb)
   where gestacao_id = p_gestacao_id and user_id = v_dono;
end;
$$;

revoke all on function public.recepcao_comprovante_add(bigint, text, text, text) from public, anon;
revoke all on function public.recepcao_comprovante_remover(bigint, text) from public, anon;
grant execute on function public.recepcao_comprovante_add(bigint, text, text, text) to authenticated;
grant execute on function public.recepcao_comprovante_remover(bigint, text) to authenticated;

-- Conferência (opcional): deve listar o bucket e as 3 policies.
--   select id, public from storage.buckets where id = 'comprovantes';
--   select policyname, cmd from pg_policies where schemaname='storage' and tablename='objects' and policyname like 'comprovantes:%';
-- Se o SQL Editor recusar `create policy ... on storage.objects` ("must be owner"), crie as 3 pelo painel
-- (Storage → Policies → comprovantes) com a expressão
--   (storage.foldername(name))[1] = public.dono_recepcao()::text   para o papel authenticated.
