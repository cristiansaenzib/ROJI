-- Ejecutar DESPUÉS de 1 y 2 (Supabase > SQL Editor > Run)

alter table products  add column if not exists disc_detal boolean not null default false;
alter table customers add column if not exists email text;
alter table customers add column if not exists city text;
alter table customers add column if not exists address text;

drop function if exists apartar(text, jsonb);
drop function if exists vender_directo(text, jsonb);
drop function if exists lookup_customer(text);
drop function if exists registrar_cliente(text, text, text);

-- Nivel de precio de UNA referencia según cantidades por talla
--   Distribuidor: 6+ uds en 3 tallas distintas, mínimo 1-1-4
--   Mayorista:   12+ uds en 3 tallas distintas, mínimo 2-2-8
create or replace function tier_for(q int[]) returns text
language plpgsql immutable as $$
declare s int[]; t int;
begin
  select array_agg(x order by x desc) into s from unnest(q) x where x > 0;
  select coalesce(sum(x),0) into t from unnest(q) x;
  if s is null or array_length(s,1) < 3 then return 'detal'; end if;
  if t >= 12 and s[1] >= 8 and s[2] >= 2 and s[3] >= 2 then return 'mayor'; end if;
  if t >= 6  and s[1] >= 4 and s[2] >= 1 and s[3] >= 1 then return 'dist';  end if;
  return 'detal';
end $$;

create or replace function order_groups(p_items jsonb)
returns table(pid text, sizes text[], qs int[])
language sql immutable as $$
  select pid, array_agg(sz order by sz), array_agg(qty order by sz)
  from (select value->>'product_id' as pid, value->>'size' as sz, sum((value->>'qty')::int)::int as qty
        from jsonb_array_elements(p_items) group by 1, 2) x
  group by pid
$$;

create or replace function apartar(p_ced text, p_name text, p_phone text, p_email text,
                                   p_city text, p_address text, p_items jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare c customers; r reservations; g record; pr products; ps product_sizes;
        d text := regexp_replace(p_ced,'\D','','g');
        v_rank int; v_type text; v_price int; v_total int := 0; v_units int; v_tier text; i int; q int;
begin
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb)) = 0 then raise exception 'Pedido vacío'; end if;
  if length(d) < 5 then raise exception 'Cédula inválida'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'Escribe tu nombre'; end if;
  if length(regexp_replace(coalesce(p_phone,''),'\D','','g')) < 7 then raise exception 'Teléfono inválido'; end if;
  if position('@' in coalesce(p_email,'')) < 2 then raise exception 'Correo inválido'; end if;

  select coalesce(max(case tier_for(qs) when 'mayor' then 3 when 'dist' then 2 else 1 end),1)
    into v_rank from order_groups(p_items);
  if v_rank > 1 and (length(trim(coalesce(p_city,''))) < 2 or length(trim(coalesce(p_address,''))) < 5) then
    raise exception 'Para compras de distribuidor o mayorista se requiere ciudad y dirección';
  end if;
  v_type := case v_rank when 3 then 'mayor' when 2 then 'dist' else 'detal' end;

  -- Guarda el cliente. Si ya existe, solo completa datos vacíos y sube de nivel; nunca sobrescribe.
  insert into customers(cedula,name,phone,email,city,address,type)
  values (d, trim(p_name), trim(p_phone), trim(p_email), nullif(trim(coalesce(p_city,'')),''), nullif(trim(coalesce(p_address,'')),''), v_type)
  on conflict (cedula) do update set
    phone   = coalesce(nullif(customers.phone,''),   excluded.phone),
    email   = coalesce(nullif(customers.email,''),   excluded.email),
    city    = coalesce(nullif(customers.city,''),    excluded.city),
    address = coalesce(nullif(customers.address,''), excluded.address),
    type    = case when (case excluded.type when 'mayor' then 3 when 'dist' then 2 else 1 end)
                      > (case customers.type when 'mayor' then 3 when 'dist' then 2 else 1 end)
                   then excluded.type else customers.type end
  returning * into c;

  insert into reservations(customer_id,status,total) values (c.id,'activo',0) returning * into r;

  for g in select * from order_groups(p_items) loop
    select * into pr from products where id = g.pid and active;
    if not found then raise exception 'Producto no disponible: %', g.pid; end if;
    v_tier := tier_for(g.qs);
    select sum(x) into v_units from unnest(g.qs) x;
    v_price := case v_tier
      when 'mayor' then pr.price_mayor
      when 'dist'  then pr.price_dist
      else round(pr.price_detal * (1 - (case when pr.disc_detal then
             (case when v_units >= 4 then 15 when v_units = 3 then 10 when v_units = 2 then 5 else 0 end)
             else 0 end) / 100.0))::int end;
    for i in 1..array_length(g.sizes,1) loop
      q := g.qs[i];
      if q <= 0 then raise exception 'Cantidad inválida'; end if;
      select * into ps from product_sizes where product_id = pr.id and size = g.sizes[i] for update;
      if not found or ps.stock - ps.reserved < q then
        raise exception 'Sin existencias suficientes: % talla %', pr.id, g.sizes[i];
      end if;
      update product_sizes set reserved = reserved + q where product_id = pr.id and size = ps.size;
      insert into reservation_items(reservation_id,product_id,product_name,size,qty,unit_price)
        values (r.id, pr.id, pr.name, ps.size, q, v_price);
      v_total := v_total + v_price * q;
    end loop;
  end loop;

  update reservations set total = v_total where id = r.id;
  return json_build_object('n', r.n, 'total', v_total);
end $$;

create or replace function vender_directo(p_ced text, p_name text, p_phone text, p_email text,
                                          p_city text, p_address text, p_items jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare a json;
begin
  a := apartar(p_ced, p_name, p_phone, p_email, p_city, p_address, p_items);
  return vender_apartado((select id from reservations where n = (a->>'n')::bigint));
end $$;

revoke execute on function vender_directo(text,text,text,text,text,text,jsonb) from public, anon;
grant  execute on function vender_directo(text,text,text,text,text,text,jsonb) to authenticated;
