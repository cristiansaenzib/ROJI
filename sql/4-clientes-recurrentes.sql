-- Ejecutar DESPUÉS de 1, 2 y 3 (Supabase > SQL Editor > Run)

create or replace function rank_of(t text) returns int
language sql immutable as $$ select case t when 'mayor' then 3 when 'dist' then 2 else 1 end $$;

-- La tablet solo recibe el primer nombre y banderas; nunca teléfono, correo ni dirección
create or replace function lookup_customer(p_ced text) returns json
language sql security definer set search_path = public as $$
  select json_build_object(
    'first', split_part(trim(name),' ',1),
    'type', type,
    'has_contact', (length(regexp_replace(coalesce(phone,''),'\D','','g')) >= 7 and position('@' in coalesce(email,'')) > 1),
    'has_addr', (length(trim(coalesce(city,''))) >= 2 and length(trim(coalesce(address,''))) >= 5))
  from customers where cedula = regexp_replace(coalesce(p_ced,''),'\D','','g') limit 1
$$;

-- Apartar: el cliente registrado puede enviar solo la cédula; el servidor usa los datos guardados.
-- Precio de cada referencia = el mejor entre el nivel del cliente y el nivel por cantidades.
create or replace function apartar(p_ced text, p_name text, p_phone text, p_email text,
                                   p_city text, p_address text, p_items jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare c customers; r reservations; g record; pr products; ps product_sizes;
        d text := regexp_replace(coalesce(p_ced,''),'\D','','g');
        v_base int := 1; v_rank int; v_gr int; v_tier text; v_price int; v_total int := 0; v_units int; i int; q int;
        m_name text; m_phone text; m_email text; m_city text; m_addr text;
begin
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb)) = 0 then raise exception 'Pedido vacío'; end if;
  if length(d) < 5 then raise exception 'Cédula inválida'; end if;

  select * into c from customers where cedula = d;
  if found then v_base := rank_of(c.type); end if;
  select coalesce(max(greatest(rank_of(tier_for(qs)), v_base)), v_base) into v_rank from order_groups(p_items);

  m_name  := coalesce(nullif(trim(c.name),''),    trim(coalesce(p_name,'')));
  m_phone := coalesce(nullif(trim(c.phone),''),   trim(coalesce(p_phone,'')));
  m_email := coalesce(nullif(trim(c.email),''),   trim(coalesce(p_email,'')));
  m_city  := coalesce(nullif(trim(c.city),''),    trim(coalesce(p_city,'')));
  m_addr  := coalesce(nullif(trim(c.address),''), trim(coalesce(p_address,'')));

  if length(m_name) < 2 then raise exception 'Escribe tu nombre'; end if;
  if length(regexp_replace(m_phone,'\D','','g')) < 7 then raise exception 'Teléfono inválido'; end if;
  if position('@' in m_email) < 2 then raise exception 'Correo inválido'; end if;
  if v_rank > 1 and (length(m_city) < 2 or length(m_addr) < 5) then
    raise exception 'Para compras de distribuidor o mayorista se requiere ciudad y dirección';
  end if;

  -- El tipo de cliente NO cambia al apartar; sube cuando el admin registra la venta final.
  insert into customers(cedula,name,phone,email,city,address,type)
  values (d, m_name, m_phone, m_email, nullif(m_city,''), nullif(m_addr,''), 'detal')
  on conflict (cedula) do update set
    phone = excluded.phone, email = excluded.email, city = excluded.city, address = excluded.address
  returning * into c;

  insert into reservations(customer_id,status,total) values (c.id,'activo',0) returning * into r;

  for g in select * from order_groups(p_items) loop
    select * into pr from products where id = g.pid and active;
    if not found then raise exception 'Producto no disponible: %', g.pid; end if;
    v_gr := greatest(rank_of(tier_for(g.qs)), v_base);
    v_tier := case v_gr when 3 then 'mayor' when 2 then 'dist' else 'detal' end;
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

-- Venta final: descuenta stock y, si el pedido cumplió distribuidor/mayorista, sube el nivel del cliente
create or replace function vender_apartado(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
declare r reservations; it reservation_items; v_rank int;
begin
  select * into r from reservations where id = p_id for update;
  if not found or r.status <> 'activo' then raise exception 'El apartado no está activo'; end if;
  for it in select * from reservation_items where reservation_id = p_id loop
    update product_sizes set stock = stock - it.qty, reserved = reserved - it.qty
      where product_id = it.product_id and size = it.size;
  end loop;
  select coalesce(max(rank_of(tier_for(qs))),1) into v_rank
    from (select array_agg(qty) qs from reservation_items where reservation_id = p_id group by product_id) x;
  update customers set type = case greatest(rank_of(type), v_rank) when 3 then 'mayor' when 2 then 'dist' else 'detal' end
    where id = r.customer_id;
  update reservations set status = 'vendido', closed_at = now() where id = p_id;
  return json_build_object('n', r.n, 'total', r.total);
end $$;
