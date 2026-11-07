--
-- PostgreSQL database dump
--

\restrict 5esKaldsUTglEPlMhDr91gBKEGIqCz5P9qPvtN0h48WObCkHenRdvW2agizUcZm

-- Dumped from database version 18.6 (Ubuntu 18.6-0ubuntu0.26.04.1)
-- Dumped by pg_dump version 18.6 (Ubuntu 18.6-0ubuntu0.26.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: VialNex; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA "VialNex";


--
-- Name: agregar_evidencia(bigint, bigint, text); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".agregar_evidencia(p_evento bigint, p_usuario bigint, p_url text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE e "VialNex".eventos_carga%ROWTYPE; v_orden INTEGER; v_id BIGINT;
BEGIN
 IF NULLIF(BTRIM(p_url),'') IS NULL THEN RAISE EXCEPTION 'URL de evidencia obligatoria'; END IF;
 SELECT * INTO e FROM "VialNex".eventos_carga WHERE id=p_evento FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Evento inexistente'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "VialNex".usuarios u
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles r ON r.id=ur.rol_id
 WHERE u.id=p_usuario AND u.activo AND
 ((r.nombre='administrador' AND (u.web OR u.movil)) OR
  (r.nombre='bodega' AND u.movil AND e.usuario_id=p_usuario))) THEN
  RAISE EXCEPTION 'Usuario sin permiso para agregar evidencia al evento'; END IF;
 SELECT id INTO v_id FROM "VialNex".evidencias WHERE evento_id=p_evento AND url=BTRIM(p_url);
 IF FOUND THEN RETURN v_id; END IF;
 SELECT COALESCE(MAX(orden),0)+1 INTO v_orden FROM "VialNex".evidencias WHERE evento_id=p_evento;
 INSERT INTO "VialNex".evidencias(evento_id,url,orden,subida_por)
 VALUES(p_evento,BTRIM(p_url),v_orden,p_usuario) RETURNING id INTO v_id;
 RETURN v_id;
END;
$$;


--
-- Name: aprobar_cargo(bigint, bigint); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".aprobar_cargo(p_cargo bigint, p_usuario bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE c "VialNex".cargos%ROWTYPE;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM "VialNex".usuarios u
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles r ON r.id=ur.rol_id
 WHERE u.id=p_usuario AND u.activo AND u.web AND r.nombre IN ('administrador','despachador')) THEN
  RAISE EXCEPTION 'Usuario sin permiso para aprobar cargos'; END IF;
 SELECT * INTO c FROM "VialNex".cargos WHERE id=p_cargo FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Cargo inexistente'; END IF;
 IF c.aprobado_en IS NOT NULL THEN RAISE EXCEPTION 'Cargo ya aprobado'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "VialNex".ventas WHERE id=c.venta_id AND estado<>'anulada') THEN
  RAISE EXCEPTION 'No se aprueba un cargo de venta anulada'; END IF;
 UPDATE "VialNex".cargos SET aprobado_por=p_usuario,aprobado_en=CURRENT_TIMESTAMP WHERE id=p_cargo;
END;
$$;


--
-- Name: asignar_orden_ruta(bigint, bigint, bigint); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".asignar_orden_ruta(p_orden bigint, p_ruta bigint, p_usuario bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE v_estado TEXT; o "VialNex".ordenes%ROWTYPE; v_secuencia INTEGER;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM "VialNex".usuarios u
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles r ON r.id=ur.rol_id
 WHERE u.id=p_usuario AND u.activo AND u.web AND r.nombre IN ('administrador','despachador')) THEN
  RAISE EXCEPTION 'Usuario sin permiso de planificación'; END IF;
 SELECT estado INTO v_estado FROM "VialNex".rutas WHERE id=p_ruta FOR UPDATE;
 IF NOT FOUND OR v_estado<>'planificada' THEN RAISE EXCEPTION 'Ruta no disponible para asignación'; END IF;
 SELECT * INTO o FROM "VialNex".ordenes WHERE id=p_orden FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Orden inexistente'; END IF;
 IF o.ruta_id IS NOT NULL THEN RAISE EXCEPTION 'Orden ya asignada a una ruta'; END IF;
 IF o.estado NOT IN ('carga_confirmada','carga_parcial') THEN
  RAISE EXCEPTION 'Orden sin carga confirmada'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "VialNex".posiciones WHERE orden_id=p_orden AND estado='cargada') THEN
  RAISE EXCEPTION 'Orden sin productos cargados'; END IF;
 UPDATE "VialNex".ordenes SET ruta_id=p_ruta WHERE id=p_orden;
 SELECT COALESCE(MAX(secuencia),0) INTO v_secuencia FROM "VialNex".paradas_ruta WHERE ruta_id=p_ruta;
 INSERT INTO "VialNex".paradas_ruta(ruta_id,guia_id,secuencia)
 SELECT p_ruta,g.id,v_secuencia+ROW_NUMBER() OVER(ORDER BY g.id)
 FROM "VialNex".guias g WHERE g.orden_id=p_orden
 AND EXISTS(SELECT 1 FROM "VialNex".posiciones p WHERE p.guia_id=g.id AND p.estado='cargada');
END;
$$;


--
-- Name: auditar_estado_orden(); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".auditar_estado_orden() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE v_usuario BIGINT; v_contexto TEXT;
BEGIN
 IF TG_OP='UPDATE' AND NEW.estado IS NOT DISTINCT FROM OLD.estado THEN RETURN NEW; END IF;
 v_contexto:=NULLIF(current_setting('vialnex.usuario_id',TRUE),'');
 IF v_contexto IS NOT NULL THEN
  v_usuario:=v_contexto::BIGINT;
  IF NOT EXISTS(SELECT 1 FROM "VialNex".usuarios WHERE id=v_usuario AND activo) THEN
   RAISE EXCEPTION 'Identidad de aplicación inválida para el historial'; END IF;
 ELSIF TG_OP='INSERT' THEN v_usuario:=NEW.creada_por;
 END IF;
 INSERT INTO "VialNex".orden_estados(orden_id,estado,estado_previo,cambiado_por,origen)
 VALUES(NEW.id,NEW.estado,CASE WHEN TG_OP='UPDATE' THEN OLD.estado ELSE NULL END,
 v_usuario,CASE WHEN TG_OP='INSERT' THEN 'creacion' ELSE 'transicion' END);
 RETURN NEW;
END;
$$;


--
-- Name: bloquear_edicion_evento(); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".bloquear_edicion_evento() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
 RAISE EXCEPTION 'Los eventos de carga no se editan ni eliminan';
END;
$$;


--
-- Name: cerrar_ruta(bigint, bigint); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".cerrar_ruta(p_ruta bigint, p_usuario bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE v_estado TEXT;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM "VialNex".usuarios u
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles ro ON ro.id=ur.rol_id
 WHERE u.id=p_usuario AND u.activo AND u.web AND ro.nombre IN ('despachador','administrador')) THEN
  RAISE EXCEPTION 'Solo despacho o administración puede cerrar ruta'; END IF;
 SELECT estado INTO v_estado FROM "VialNex".rutas WHERE id=p_ruta FOR UPDATE;
 IF NOT FOUND OR v_estado<>'en_ruta' THEN RAISE EXCEPTION 'Ruta no está en ejecución'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "VialNex".paradas_ruta WHERE ruta_id=p_ruta) THEN
  RAISE EXCEPTION 'Ruta sin paradas'; END IF;
 IF EXISTS(SELECT 1 FROM "VialNex".paradas_ruta p WHERE p.ruta_id=p_ruta
 AND NOT EXISTS(SELECT 1 FROM "VialNex".entregas e WHERE e.parada_id=p.id)) THEN
  RAISE EXCEPTION 'Hay paradas sin intento de entrega registrado'; END IF;
 UPDATE "VialNex".ordenes SET estado='cerrada' WHERE ruta_id=p_ruta AND estado='en_ruta';
 UPDATE "VialNex".rutas SET estado='cerrada',cierre_en=CURRENT_TIMESTAMP WHERE id=p_ruta;
 INSERT INTO "VialNex".hitos_ruta(ruta_id,registrado_por,tipo,observacion)
 VALUES(p_ruta,p_usuario,'cierre','Jornada cerrada; consultar resultados de cada parada');
END;
$$;


--
-- Name: clasificar_tramo(numeric, numeric, numeric, numeric); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".clasificar_tramo(p_largo numeric, p_ancho numeric, p_alto numeric, p_peso numeric) RETURNS bigint
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE v_id BIGINT;
BEGIN
 IF p_largo IS NULL OR p_ancho IS NULL OR p_alto IS NULL OR p_peso IS NULL
 OR p_largo <= 0 OR p_ancho <= 0 OR p_alto <= 0 OR p_peso <= 0 THEN
  RAISE EXCEPTION 'Dimensiones y peso deben ser positivos';
 END IF;
 SELECT id INTO v_id FROM "VialNex".tramos
 WHERE (lado_max_cm IS NULL OR GREATEST(p_largo,p_ancho,p_alto) <= lado_max_cm)
 AND (peso_max_kg IS NULL OR p_peso <= peso_max_kg)
 ORDER BY prioridad LIMIT 1;
 IF v_id IS NULL THEN RAISE EXCEPTION 'No existe tramo configurado para esta carga'; END IF;
 RETURN v_id;
END;
$$;


--
-- Name: confirmar_carga(bigint, bigint); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".confirmar_carga(p_orden bigint, p_usuario bigint) RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE o "VialNex".ordenes%ROWTYPE;
 v_total BIGINT; v_cargadas BIGINT; v_pendientes BIGINT; v_estado TEXT;
BEGIN
 IF NOT EXISTS (SELECT 1 FROM "VialNex".usuarios u
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles r ON r.id=ur.rol_id
 WHERE u.id=p_usuario AND u.activo
 AND r.nombre IN ('bodega','despachador','administrador')
 AND ((r.nombre='bodega' AND u.movil) OR
      (r.nombre IN ('despachador','administrador') AND (u.web OR u.movil)))) THEN
  RAISE EXCEPTION 'Usuario sin permiso para confirmar carga';
 END IF;
 SELECT * INTO o FROM "VialNex".ordenes WHERE id=p_orden FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Orden inexistente'; END IF;
 IF o.estado <> 'en_bodega' THEN RAISE EXCEPTION 'Orden ya confirmada o fuera de bodega'; END IF;
 SELECT COUNT(*), COUNT(*) FILTER(WHERE estado='cargada'),
 COUNT(*) FILTER(WHERE estado='pendiente') INTO v_total,v_cargadas,v_pendientes
 FROM "VialNex".posiciones WHERE orden_id=p_orden;
 IF v_total=0 THEN RAISE EXCEPTION 'Orden sin posiciones'; END IF;
 IF v_pendientes>0 THEN RAISE EXCEPTION 'Quedan posiciones pendientes de revisar'; END IF;
 IF v_cargadas=0 THEN RAISE EXCEPTION 'No hay productos cargados: no se autoriza salida'; END IF;
 IF EXISTS (SELECT 1 FROM "VialNex".posiciones p WHERE p.orden_id=p_orden
 AND (p.estado NOT IN ('cargada','sin_stock','danada')
 OR NOT EXISTS(SELECT 1 FROM "VialNex".eventos_carga e
 WHERE e.posicion_id=p.id AND e.tipo=p.estado))) THEN
  RAISE EXCEPTION 'Hay posiciones sin evento que respalde su estado';
 END IF;
 v_estado := CASE WHEN v_cargadas=v_total THEN 'carga_confirmada' ELSE 'carga_parcial' END;
 UPDATE "VialNex".ordenes SET estado=v_estado,
 carga_confirmada_por=p_usuario,carga_confirmada_en=CURRENT_TIMESTAMP
 WHERE id=p_orden;
 RETURN v_estado;
END;
$$;


--
-- Name: copiar_evidencia_principal(); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".copiar_evidencia_principal() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
 IF NULLIF(BTRIM(NEW.evidencia_url),'') IS NOT NULL THEN
  INSERT INTO "VialNex".evidencias(evento_id,url,orden,subida_por,subida_en)
  VALUES(NEW.id,NEW.evidencia_url,1,NEW.usuario_id,NEW.ocurrido_en);
 END IF;
 RETURN NEW;
END;
$$;


--
-- Name: cotizar_producto(bigint, numeric, numeric, numeric, numeric, integer, date); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".cotizar_producto(p_zona bigint, p_largo numeric, p_ancho numeric, p_alto numeric, p_peso numeric, p_cantidad integer DEFAULT 1, p_fecha date DEFAULT CURRENT_DATE) RETURNS TABLE(tramo_id bigint, tarifa_id bigint, precio_unitario numeric, subtotal numeric)
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE v_tramo BIGINT; v_total BIGINT;
BEGIN
 IF p_fecha IS NULL OR p_cantidad IS NULL OR p_cantidad<=0 THEN
  RAISE EXCEPTION 'Fecha y cantidad positiva obligatorias'; END IF;
 v_tramo:="VialNex".clasificar_tramo(p_largo,p_ancho,p_alto,p_peso);
 SELECT COUNT(*) INTO v_total FROM "VialNex".tarifas t
 WHERE t.zona_id=p_zona AND t.tramo_id=v_tramo
 AND t.vigente_desde<=p_fecha AND (t.vigente_hasta IS NULL OR t.vigente_hasta>=p_fecha);
 IF v_total=0 THEN RAISE EXCEPTION 'No existe tarifa vigente para zona y tramo'; END IF;
 IF v_total>1 THEN RAISE EXCEPTION 'Hay tarifas vigentes superpuestas para zona y tramo'; END IF;
 RETURN QUERY SELECT v_tramo,t.id,t.monto,ROUND(t.monto*p_cantidad,2)
 FROM "VialNex".tarifas t WHERE t.zona_id=p_zona AND t.tramo_id=v_tramo
 AND t.vigente_desde<=p_fecha AND (t.vigente_hasta IS NULL OR t.vigente_hasta>=p_fecha);
END;
$$;


--
-- Name: crear_cargo(bigint, bigint, text, numeric, bigint, text); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".crear_cargo(p_venta bigint, p_usuario bigint, p_concepto text, p_monto numeric, p_entrega bigint DEFAULT NULL::bigint, p_justificacion text DEFAULT NULL::text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_id BIGINT;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM "VialNex".usuarios u
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles r ON r.id=ur.rol_id
 WHERE u.id=p_usuario AND u.activo AND u.web AND r.nombre IN ('administrador','despachador')) THEN
  RAISE EXCEPTION 'Usuario sin permiso para crear cargos'; END IF;
 IF p_monto IS NULL OR p_monto<=0 OR p_monto<>ROUND(p_monto,2) THEN
  RAISE EXCEPTION 'Monto debe ser positivo y tener como máximo dos decimales'; END IF;
 IF NULLIF(BTRIM(p_concepto),'') IS NULL THEN RAISE EXCEPTION 'Concepto obligatorio'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "VialNex".ventas WHERE id=p_venta AND estado<>'anulada') THEN
  RAISE EXCEPTION 'Venta inexistente o anulada'; END IF;
 IF p_entrega IS NOT NULL THEN
  IF NOT EXISTS(SELECT 1 FROM "VialNex".entregas e
  JOIN "VialNex".paradas_ruta p ON p.id=e.parada_id
  JOIN "VialNex".guias g ON g.id=p.guia_id
  WHERE e.id=p_entrega AND g.venta_id=p_venta) THEN
   RAISE EXCEPTION 'Entrega ajena a la venta o inexistente'; END IF;
  IF NULLIF(BTRIM(p_justificacion),'') IS NULL THEN
   RAISE EXCEPTION 'Cargo asociado a entrega requiere justificación'; END IF;
 END IF;
 INSERT INTO "VialNex".cargos(venta_id,entrega_id,concepto,monto,creado_por,justificacion)
 VALUES(p_venta,p_entrega,BTRIM(p_concepto),p_monto,p_usuario,p_justificacion)
 RETURNING id INTO v_id;
 RETURN v_id;
END;
$$;


--
-- Name: crear_reposicion(bigint, bigint, text); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".crear_reposicion(p_origen bigint, p_usuario bigint, p_codigo text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE o "VialNex".ordenes%ROWTYPE; v_nueva BIGINT;
 v_guia BIGINT; g RECORD;
BEGIN
 IF NULLIF(BTRIM(p_codigo),'') IS NULL THEN RAISE EXCEPTION 'Código de orden obligatorio'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "VialNex".usuarios u
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles r ON r.id=ur.rol_id
 WHERE u.id=p_usuario AND u.activo AND u.web
 AND r.nombre IN ('despachador','administrador')) THEN
  RAISE EXCEPTION 'Solo despacho o administración puede reprogramar';
 END IF;
 SELECT * INTO o FROM "VialNex".ordenes WHERE id=p_origen FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Orden original inexistente'; END IF;
 -- Se admite reprogramar después de iniciar/cerrar la ruta si la carga fue parcial.
 IF o.estado <> 'carga_parcial' AND NOT
 (o.estado IN ('en_ruta','cerrada') AND o.carga_confirmada_en IS NOT NULL
 AND EXISTS(SELECT 1 FROM "VialNex".posiciones WHERE orden_id=p_origen
 AND estado IN ('sin_stock','danada'))) THEN
  RAISE EXCEPTION 'Solo una carga parcial puede generar reposición';
 END IF;
 IF EXISTS(SELECT 1 FROM "VialNex".ordenes WHERE orden_origen_id=p_origen) THEN
  RAISE EXCEPTION 'La orden ya tiene reposición';
 END IF;
 IF EXISTS(SELECT 1 FROM "VialNex".posiciones WHERE orden_id=p_origen AND estado='pendiente')
 OR NOT EXISTS(SELECT 1 FROM "VialNex".posiciones WHERE orden_id=p_origen AND estado='cargada')
 OR NOT EXISTS(SELECT 1 FROM "VialNex".posiciones WHERE orden_id=p_origen AND estado IN ('sin_stock','danada')) THEN
  RAISE EXCEPTION 'La carga original no cumple las condiciones de parcial';
 END IF;
 INSERT INTO "VialNex".ordenes(codigo,creada_por,orden_origen_id)
 VALUES(BTRIM(p_codigo),p_usuario,p_origen) RETURNING id INTO v_nueva;
 FOR g IN SELECT DISTINCT gu.id,gu.venta_id FROM "VialNex".guias gu
 JOIN "VialNex".posiciones p ON p.guia_id=gu.id
 WHERE p.orden_id=p_origen AND p.estado IN ('sin_stock','danada') LOOP
  INSERT INTO "VialNex".guias(numero,orden_id,venta_id)
  VALUES('INT-REP-'||v_nueva||'-'||g.id,v_nueva,g.venta_id)
  RETURNING id INTO v_guia;
  INSERT INTO "VialNex".posiciones(orden_id,guia_id,detalle_venta_id,codigo_barras,cantidad_bultos)
  SELECT v_nueva,v_guia,detalle_venta_id,codigo_barras,cantidad_bultos
  FROM "VialNex".posiciones WHERE orden_id=p_origen AND guia_id=g.id
  AND estado IN ('sin_stock','danada');
 END LOOP;
 RETURN v_nueva;
END;
$$;


--
-- Name: crear_ruta(text, bigint, bigint, date, bigint); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".crear_ruta(p_codigo text, p_vehiculo bigint, p_personal bigint, p_fecha date, p_usuario bigint) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_id BIGINT; v_veh "VialNex".vehiculos%ROWTYPE;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM "VialNex".usuarios u
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles r ON r.id=ur.rol_id
 WHERE u.id=p_usuario AND u.activo AND u.web AND r.nombre IN ('administrador','despachador')) THEN
  RAISE EXCEPTION 'Usuario sin permiso de planificación'; END IF;
 IF NULLIF(BTRIM(p_codigo),'') IS NULL OR p_fecha IS NULL THEN
  RAISE EXCEPTION 'Código y fecha de ruta obligatorios'; END IF;
 SELECT * INTO v_veh FROM "VialNex".vehiculos WHERE id=p_vehiculo FOR UPDATE;
 IF NOT FOUND OR v_veh.estado<>'operativo' THEN RAISE EXCEPTION 'Vehículo no operativo'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "VialNex".personal pe
 JOIN "VialNex".usuarios u ON u.id=pe.usuario_id
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles r ON r.id=ur.rol_id
 WHERE pe.id=p_personal AND pe.activo AND u.activo AND u.movil AND r.nombre='transporte') THEN
  RAISE EXCEPTION 'Personal sin cuenta móvil de transporte activa'; END IF;
 INSERT INTO "VialNex".rutas(codigo,vehiculo_id,conductor_id,fecha)
 VALUES(BTRIM(p_codigo),p_vehiculo,p_personal,p_fecha) RETURNING id INTO v_id;
 RETURN v_id;
END;
$$;


--
-- Name: generar_orden_venta(bigint, bigint, text, jsonb); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".generar_orden_venta(p_venta bigint, p_usuario bigint, p_codigo text, p_posiciones jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_venta "VialNex".ventas%ROWTYPE;
 v_orden BIGINT; v_guia BIGINT; v_item JSONB;
 v_detalle BIGINT; v_bultos INTEGER; v_barra TEXT; v_total BIGINT;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM "VialNex".usuarios u
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles r ON r.id=ur.rol_id
 WHERE u.id=p_usuario AND u.activo AND u.web
 AND r.nombre IN ('despachador','administrador')) THEN
  RAISE EXCEPTION 'Usuario sin permiso para generar órdenes'; END IF;
 IF NULLIF(BTRIM(p_codigo),'') IS NULL THEN RAISE EXCEPTION 'Código de orden obligatorio'; END IF;
 SELECT * INTO v_venta FROM "VialNex".ventas WHERE id=p_venta FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Venta inexistente'; END IF;
 IF v_venta.estado='anulada' THEN RAISE EXCEPTION 'Venta anulada'; END IF;
 -- Una venta con orden previa no se vuelve a despachar desde esta función.
 -- La cancelación/reemisión requiere su propio proceso explícito.
 IF EXISTS(SELECT 1 FROM "VialNex".guias WHERE venta_id=p_venta) THEN
  RAISE EXCEPTION 'La venta ya tiene una orden; usar reposición cuando corresponda'; END IF;
 IF p_posiciones IS NULL OR jsonb_typeof(p_posiciones)<>'array' THEN
  RAISE EXCEPTION 'Posiciones debe ser un arreglo'; END IF;
 SELECT COUNT(*) INTO v_total FROM "VialNex".detalle_ventas WHERE venta_id=p_venta;
 IF v_total=0 OR jsonb_array_length(p_posiciones)<>v_total THEN
  RAISE EXCEPTION 'Se debe incluir una posición por cada detalle de venta'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_posiciones) x
 GROUP BY (x->>'detalle_id')::BIGINT HAVING COUNT(*)>1) THEN
  RAISE EXCEPTION 'Detalle repetido en la solicitud'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_posiciones) x
 GROUP BY BTRIM(x->>'codigo_barras') HAVING COUNT(*)>1) THEN
  RAISE EXCEPTION 'Código de barras repetido en la orden'; END IF;
 INSERT INTO "VialNex".ordenes(codigo,creada_por)
 VALUES(BTRIM(p_codigo),p_usuario) RETURNING id INTO v_orden;
 INSERT INTO "VialNex".guias(numero,orden_id,venta_id)
 VALUES('INT-OT-'||v_orden,v_orden,p_venta) RETURNING id INTO v_guia;
 FOR v_item IN SELECT value FROM jsonb_array_elements(p_posiciones) LOOP
  v_detalle:=(v_item->>'detalle_id')::BIGINT;
  v_bultos:=(v_item->>'cantidad_bultos')::INTEGER;
  v_barra:=NULLIF(BTRIM(v_item->>'codigo_barras'),'');
  IF NOT EXISTS(SELECT 1 FROM "VialNex".detalle_ventas WHERE id=v_detalle AND venta_id=p_venta) THEN
   RAISE EXCEPTION 'Detalle ajeno a la venta'; END IF;
  IF v_bultos IS NULL OR v_bultos<=0 THEN RAISE EXCEPTION 'Cantidad de bultos inválida'; END IF;
  IF v_barra IS NULL THEN RAISE EXCEPTION 'Código de barras obligatorio'; END IF;
  INSERT INTO "VialNex".posiciones(orden_id,guia_id,detalle_venta_id,codigo_barras,cantidad_bultos)
  VALUES(v_orden,v_guia,v_detalle,v_barra,v_bultos);
 END LOOP;
 UPDATE "VialNex".ventas SET estado='confirmada' WHERE id=p_venta;
 RETURN v_orden;
END;
$$;


--
-- Name: iniciar_ruta(bigint, bigint); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".iniciar_ruta(p_ruta bigint, p_usuario bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE r "VialNex".rutas%ROWTYPE; v_vehiculo BIGINT; v_operativo TEXT;
BEGIN
 SELECT vehiculo_id INTO v_vehiculo FROM "VialNex".rutas WHERE id=p_ruta;
 IF NOT FOUND THEN RAISE EXCEPTION 'Ruta inexistente'; END IF;
 -- Serializa salidas del mismo camión; después bloquea personal y ruta.
 SELECT estado INTO v_operativo FROM "VialNex".vehiculos WHERE id=v_vehiculo FOR UPDATE;
 SELECT * INTO r FROM "VialNex".rutas WHERE id=p_ruta;
 PERFORM 1 FROM "VialNex".personal WHERE id=r.conductor_id FOR UPDATE;
 SELECT * INTO r FROM "VialNex".rutas WHERE id=p_ruta FOR UPDATE;
 IF r.vehiculo_id<>v_vehiculo THEN RAISE EXCEPTION 'Asignación cambió; reintentar salida'; END IF;
 IF r.estado<>'planificada' THEN RAISE EXCEPTION 'Ruta ya iniciada o no planificada'; END IF;
 IF v_operativo<>'operativo' THEN RAISE EXCEPTION 'Vehículo no operativo'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "VialNex".personal pe
 JOIN "VialNex".usuarios u ON u.id=pe.usuario_id
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles ro ON ro.id=ur.rol_id
 WHERE pe.id=r.conductor_id AND pe.activo AND u.id=p_usuario
 AND u.activo AND u.movil AND ro.nombre='transporte') THEN
  RAISE EXCEPTION 'Usuario no asignado a esta ruta como transporte'; END IF;
 IF EXISTS(SELECT 1 FROM "VialNex".rutas
 WHERE id<>p_ruta AND estado='en_ruta'
 AND (vehiculo_id=r.vehiculo_id OR conductor_id=r.conductor_id)) THEN
  RAISE EXCEPTION 'Vehículo o personal ya está en otra ruta activa'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "VialNex".ordenes WHERE ruta_id=p_ruta) THEN
  RAISE EXCEPTION 'Ruta sin órdenes'; END IF;
 IF EXISTS(SELECT 1 FROM "VialNex".ordenes WHERE ruta_id=p_ruta
 AND estado NOT IN ('carga_confirmada','carga_parcial')) THEN
  RAISE EXCEPTION 'Ruta con órdenes sin carga confirmada'; END IF;
 UPDATE "VialNex".ordenes SET estado='en_ruta' WHERE ruta_id=p_ruta;
 UPDATE "VialNex".rutas SET estado='en_ruta',salida_en=CURRENT_TIMESTAMP WHERE id=p_ruta;
 INSERT INTO "VialNex".hitos_ruta(ruta_id,registrado_por,tipo,observacion)
 VALUES(p_ruta,p_usuario,'salida','Inicio de ruta');
END;
$$;


--
-- Name: marcar_usuario_modificado(); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".marcar_usuario_modificado() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE v_quien TEXT;
BEGIN
    -- Un UPDATE que no cambia nada no cuenta como modificacion. Sin
    -- esto, cualquier "guardar" sin cambios movería la fecha y el dato
    -- dejaria de significar "cuando cambio algo".
    IF NEW IS NOT DISTINCT FROM OLD THEN
        RETURN NEW;
    END IF;

    -- ultimo_acceso_en lo escribe cada login. Si contara como
    -- modificacion, la fecha diria "modificado" cada vez que la persona
    -- entra, que no es lo que nadie espera leer en esa columna.
    IF NEW.ultimo_acceso_en IS DISTINCT FROM OLD.ultimo_acceso_en
       AND (to_jsonb(NEW) - 'ultimo_acceso_en')
            = (to_jsonb(OLD) - 'ultimo_acceso_en') THEN
        RETURN NEW;
    END IF;

    NEW.modificado_en := CURRENT_TIMESTAMP;

    v_quien := NULLIF(current_setting('vialnex.usuario_id', TRUE), '');
    IF v_quien IS NOT NULL THEN
        NEW.modificado_por := v_quien::BIGINT;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: proteger_cargo_aprobado(); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".proteger_cargo_aprobado() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
 IF OLD.aprobado_en IS NOT NULL OR EXISTS(SELECT 1 FROM "VialNex".pagos WHERE cargo_id=OLD.id) THEN
  RAISE EXCEPTION 'Cargo aprobado no se modifica ni elimina'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END;
$$;


--
-- Name: proteger_entrega_bulto(); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".proteger_entrega_bulto() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION
      'El resultado de un bulto no se modifica ni se elimina';
END;
$$;


--
-- Name: proteger_historial_bodega(); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".proteger_historial_bodega() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN RAISE EXCEPTION 'Evidencias e historial no se editan ni eliminan'; END;
$$;


--
-- Name: proteger_intento_entrega(); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".proteger_intento_entrega() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN RAISE EXCEPTION 'Los intentos de entrega no se editan ni eliminan'; END;
$$;


--
-- Name: proteger_pago(); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".proteger_pago() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN RAISE EXCEPTION 'Los pagos no se editan ni eliminan; requieren reverso contable'; END;
$$;


--
-- Name: proteger_posicion_procesada(); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".proteger_posicion_procesada() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE v_estado TEXT;
BEGIN
 SELECT estado INTO v_estado FROM "VialNex".ordenes
 WHERE id=OLD.orden_id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM "VialNex".eventos_carga WHERE posicion_id=OLD.id)
 OR v_estado <> 'en_bodega' THEN
  RAISE EXCEPTION 'Posición procesada o de orden confirmada: no se modifica ni elimina';
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END;
$$;


--
-- Name: registrar_carga(bigint, text, bigint, text, text, text); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".registrar_carga(p_orden bigint, p_codigo text, p_usuario bigint, p_estado text DEFAULT 'cargada'::text, p_foto text DEFAULT NULL::text, p_observacion text DEFAULT NULL::text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE o "VialNex".ordenes%ROWTYPE;
 p "VialNex".posiciones%ROWTYPE; v_evento BIGINT;
BEGIN
 IF NOT EXISTS (SELECT 1 FROM "VialNex".usuarios u
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles r ON r.id=ur.rol_id
 WHERE u.id=p_usuario AND u.activo AND u.movil
 AND r.nombre IN ('bodega','administrador')) THEN
  RAISE EXCEPTION 'Usuario sin acceso autorizado a bodega móvil';
 END IF;
 IF p_estado NOT IN ('cargada','sin_stock','danada') OR p_estado IS NULL THEN
  RAISE EXCEPTION 'Estado de posición inválido';
 END IF;
 SELECT * INTO o FROM "VialNex".ordenes WHERE id=p_orden FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Orden inexistente'; END IF;
 IF o.estado <> 'en_bodega' THEN RAISE EXCEPTION 'La orden ya no admite carga'; END IF;
 SELECT * INTO p FROM "VialNex".posiciones
 WHERE orden_id=p_orden AND codigo_barras=p_codigo FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Código ajeno a la orden'; END IF;
 IF p.estado <> 'pendiente' THEN RAISE EXCEPTION 'Posición ya procesada'; END IF;
 IF p_estado='danada' AND NULLIF(BTRIM(p_foto),'') IS NULL THEN
  RAISE EXCEPTION 'Producto dañado requiere fotografía';
 END IF;
 UPDATE "VialNex".posiciones SET estado=p_estado,
 foto_url=NULLIF(BTRIM(p_foto),''), marcada_por=p_usuario,
 marcada_en=CURRENT_TIMESTAMP, observaciones=p_observacion WHERE id=p.id;
 INSERT INTO "VialNex".eventos_carga(posicion_id,usuario_id,tipo,evidencia_url,observacion)
 VALUES(p.id,p_usuario,p_estado,NULLIF(BTRIM(p_foto),''),p_observacion)
 RETURNING id INTO v_evento;
 RETURN v_evento;
END;
$$;


--
-- Name: registrar_entrega(bigint, bigint, text, text, text, bigint, text); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".registrar_entrega(p_parada bigint, p_usuario bigint, p_resultado text, p_foto text, p_firma text DEFAULT NULL::text, p_motivo bigint DEFAULT NULL::bigint, p_observacion text DEFAULT NULL::text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_ruta BIGINT; v_estado TEXT; v_ultimo TEXT; v_id BIGINT;
BEGIN
 SELECT ruta_id INTO v_ruta FROM "VialNex".paradas_ruta WHERE id=p_parada;
 IF NOT FOUND THEN RAISE EXCEPTION 'Parada inexistente'; END IF;
 SELECT estado INTO v_estado FROM "VialNex".rutas WHERE id=v_ruta FOR UPDATE;
 IF v_estado<>'en_ruta' THEN RAISE EXCEPTION 'Ruta no está en ejecución'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "VialNex".rutas rt
 JOIN "VialNex".personal pe ON pe.id=rt.conductor_id
 JOIN "VialNex".usuarios u ON u.id=pe.usuario_id
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles ro ON ro.id=ur.rol_id
 WHERE rt.id=v_ruta AND u.id=p_usuario AND pe.activo AND u.activo
 AND u.movil AND ro.nombre='transporte') THEN
  RAISE EXCEPTION 'Usuario no asignado al transporte de esta ruta'; END IF;
 IF p_resultado IS NULL OR p_resultado NOT IN ('entregada','fallida') THEN
  RAISE EXCEPTION 'Resultado de entrega inválido'; END IF;
 IF NULLIF(BTRIM(p_foto),'') IS NULL THEN RAISE EXCEPTION 'Entrega requiere referencia de fotografía'; END IF;
 IF p_resultado='entregada' AND (NULLIF(BTRIM(p_firma),'') IS NULL OR p_motivo IS NOT NULL) THEN
  RAISE EXCEPTION 'Entrega exitosa requiere firma y no admite motivo de fallo'; END IF;
 IF p_resultado='fallida' AND (p_motivo IS NULL OR NOT EXISTS(
 SELECT 1 FROM "VialNex".motivos_entrega_fallida WHERE id=p_motivo)) THEN
  RAISE EXCEPTION 'Entrega fallida requiere motivo válido'; END IF;
 SELECT resultado INTO v_ultimo FROM "VialNex".entregas
 WHERE parada_id=p_parada ORDER BY id DESC LIMIT 1;
 IF v_ultimo='entregada' THEN RAISE EXCEPTION 'La parada ya fue entregada'; END IF;
 INSERT INTO "VialNex".entregas(parada_id,registrada_por,resultado,motivo_id,foto_url,firma_url,observacion)
 VALUES(p_parada,p_usuario,p_resultado,p_motivo,BTRIM(p_foto),NULLIF(BTRIM(p_firma),''),p_observacion)
 RETURNING id INTO v_id;
 INSERT INTO "VialNex".hitos_ruta(ruta_id,registrado_por,tipo,observacion,evidencia_url)
 VALUES(v_ruta,p_usuario,CASE WHEN p_resultado='entregada' THEN 'llegada' ELSE 'incidencia' END,
 'Parada '||p_parada||': '||p_resultado,BTRIM(p_foto));
 RETURN v_id;
END;
$$;


--
-- Name: registrar_entrega_detalle(bigint, bigint, text, text, text, bigint, text, jsonb); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".registrar_entrega_detalle(p_parada bigint, p_usuario bigint, p_resultado text, p_foto text, p_firma text, p_motivo bigint DEFAULT NULL::bigint, p_observacion text DEFAULT NULL::text, p_bultos jsonb DEFAULT NULL::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_entrega    bigint;
    v_guia       bigint;
    v_orden      bigint;
    v_codigo     text;
    v_a_bordo    bigint;
    v_devueltos  bigint;
    v_reposicion bigint;
    v_entregados bigint;
BEGIN
    -- 1. La entrega, con todas las validaciones que ya existian.
    v_entrega := registrar_entrega(
        p_parada, p_usuario, p_resultado, p_foto, p_firma,
        p_motivo, p_observacion);

    SELECT pr.guia_id, g.orden_id, o.codigo
      INTO v_guia, v_orden, v_codigo
      FROM paradas_ruta pr
      JOIN guias   g ON g.id = pr.guia_id
      JOIN ordenes o ON o.id = g.orden_id
     WHERE pr.id = p_parada;

    -- 2. El detalle. Sin lista, se deduce del resultado de la parada.
    IF p_bultos IS NULL THEN
        INSERT INTO entregas_bultos (entrega_id, posicion_id, resultado, motivo_id)
        SELECT v_entrega, p.id,
               CASE WHEN p_resultado = 'entregada' THEN 'entregada' ELSE 'devuelta' END,
               CASE WHEN p_resultado = 'entregada' THEN NULL ELSE p_motivo END
          FROM posiciones p
         WHERE p.guia_id = v_guia
           AND p.estado  = 'cargada'
           AND NOT EXISTS (SELECT 1 FROM entregas_bultos eb WHERE eb.posicion_id = p.id);
    ELSE
        -- Cada bulto de la lista tiene que ser de esta guia y haber
        -- subido al camion. Un bulto excluido en bodega por falta de
        -- stock nunca viajo: decir que se entrego seria mentira, y
        -- decir que se devolvio tambien.
        IF EXISTS (
            SELECT 1
              FROM jsonb_array_elements(p_bultos) b
              LEFT JOIN posiciones p
                     ON p.id = (b->>'posicion_id')::bigint
                    AND p.guia_id = v_guia
                    AND p.estado = 'cargada'
             WHERE p.id IS NULL)
        THEN
            RAISE EXCEPTION
              'Hay bultos que no pertenecen a esta parada o que no se cargaron';
        END IF;

        INSERT INTO entregas_bultos (entrega_id, posicion_id, resultado, motivo_id)
        SELECT v_entrega,
               (b->>'posicion_id')::bigint,
               b->>'resultado',
               (b->>'motivo_id')::bigint
          FROM jsonb_array_elements(p_bultos) b;

        -- Ningun bulto de la parada puede quedar sin respuesta: el
        -- camion se va y alguien tiene que saber donde quedo cada uno.
        SELECT count(*) INTO v_a_bordo
          FROM posiciones p
         WHERE p.guia_id = v_guia
           AND p.estado  = 'cargada'
           AND NOT EXISTS (SELECT 1 FROM entregas_bultos eb WHERE eb.posicion_id = p.id);

        IF v_a_bordo > 0 THEN
            RAISE EXCEPTION
              'Quedan % bultos de esta parada sin indicar si se entregaron o volvieron',
              v_a_bordo;
        END IF;
    END IF;

    -- 3. ¿Le queda algo a la orden arriba del camion?
    --    Una orden puede tener varias guias, o sea varias paradas. Se
    --    cierra cuando la ultima se resolvio, no en la primera.
    SELECT count(*) INTO v_a_bordo
      FROM posiciones p
     WHERE p.orden_id = v_orden
       AND p.estado   = 'cargada'
       AND NOT EXISTS (SELECT 1 FROM entregas_bultos eb WHERE eb.posicion_id = p.id);

    IF v_a_bordo > 0 THEN
        RETURN jsonb_build_object(
            'entrega_id',  v_entrega,
            'orden',       v_codigo,
            'orden_cerrada', false,
            'bultos_a_bordo', v_a_bordo);
    END IF;

    -- 4. Se termino. El cierre pasa validar_integridad_bodega sin
    --    ayuda: las posiciones siguen en 'cargada' —no las tocamos— y
    --    carga_confirmada_en ya estaba puesto desde bodega.
    UPDATE ordenes
       SET estado = 'cerrada'
     WHERE id = v_orden
       AND estado = 'en_ruta';

    SELECT count(*) FILTER (WHERE eb.resultado = 'devuelta'),
           count(*) FILTER (WHERE eb.resultado = 'entregada')
      INTO v_devueltos, v_entregados
      FROM entregas_bultos eb
      JOIN posiciones p ON p.id = eb.posicion_id
     WHERE p.orden_id = v_orden;

    -- 5. Si volvio algo, la reposicion. Una sola por orden, que es lo
    --    que impone vn_una_reposicion: si vuelven tres bultos de dos
    --    paradas distintas, los tres van a la misma.
    IF v_devueltos > 0 THEN
        INSERT INTO ordenes (codigo, creada_por, estado, orden_origen_id, observaciones)
        SELECT left(o.codigo || '-R', 30), p_usuario, 'por_revisar', o.id,
               'Reposicion automatica: ' || v_devueltos || ' bulto(s) devuelto(s)'
          FROM ordenes o
         WHERE o.id = v_orden
        RETURNING id INTO v_reposicion;

        -- Una guia nueva por cada guia que tuvo devoluciones. El numero
        -- se deriva del original.
        --
        --   >>> A RESOLVER CON EL NEGOCIO: si el numero de guia es un
        --   folio del SII, no puede inventarse; tiene que salir de la
        --   correlativa. Esto sirve para la maqueta.
        --
        -- venta_id se copia del original porque validar_integridad_bodega
        -- exige que g.venta_id coincida con el detalle_ventas de cada
        -- posicion. Cambiarlo rompe la primera de sus tres reglas.
        INSERT INTO guias (numero, orden_id, venta_id)
        SELECT left(g.numero || '-R', 40), v_reposicion, g.venta_id
          FROM guias g
         WHERE g.orden_id = v_orden
           AND EXISTS (
               SELECT 1 FROM posiciones p
                 JOIN entregas_bultos eb ON eb.posicion_id = p.id
                WHERE p.guia_id = g.id AND eb.resultado = 'devuelta');

        -- El bulto vuelve con su misma etiqueta fisica, asi que se
        -- copia el codigo de barras: cuando se reintente, el bodeguero
        -- escanea exactamente la misma. El unique es (orden_id,
        -- codigo_barras), asi que repetirlo en otra orden no choca.
        INSERT INTO posiciones (orden_id, guia_id, detalle_venta_id,
                                codigo_barras, cantidad_bultos, estado, observaciones)
        SELECT v_reposicion, ng.id, p.detalle_venta_id,
               p.codigo_barras, p.cantidad_bultos, 'pendiente',
               'Devuelto: ' || m.nombre
          FROM posiciones p
          JOIN entregas_bultos eb ON eb.posicion_id = p.id
          JOIN motivos_entrega_fallida m ON m.id = eb.motivo_id
          JOIN guias og ON og.id = p.guia_id
          JOIN guias ng ON ng.orden_id = v_reposicion
                       AND ng.numero = left(og.numero || '-R', 40)
         WHERE p.orden_id = v_orden
           AND eb.resultado = 'devuelta';
    END IF;

    RETURN jsonb_build_object(
        'entrega_id',       v_entrega,
        'orden',            v_codigo,
        'orden_cerrada',    true,
        'bultos_entregados', v_entregados,
        'bultos_devueltos',  v_devueltos,
        'con_observaciones', v_devueltos > 0,
        'reposicion_id',     v_reposicion);
END;
$$;


--
-- Name: registrar_pago(bigint, bigint, numeric, text, text, timestamp with time zone); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".registrar_pago(p_cargo bigint, p_usuario bigint, p_monto numeric, p_medio text, p_referencia text, p_fecha timestamp with time zone DEFAULT CURRENT_TIMESTAMP) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_id BIGINT;
BEGIN
 IF p_monto IS NULL OR p_monto<=0 OR p_monto<>ROUND(p_monto,2) THEN
  RAISE EXCEPTION 'Monto de pago inválido'; END IF;
 INSERT INTO "VialNex".pagos(cargo_id,monto,medio,referencia,pagado_en,registrado_por)
 VALUES(p_cargo,p_monto,p_medio,p_referencia,p_fecha,p_usuario) RETURNING id INTO v_id;
 RETURN v_id;
END;
$$;


--
-- Name: registrar_venta(bigint, bigint, bigint, text, text, date, jsonb, jsonb); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".registrar_venta(p_cliente bigint, p_usuario bigint, p_zona bigint, p_destinatario text, p_direccion text, p_fecha_despacho date, p_productos jsonb, p_recargos jsonb DEFAULT '[]'::jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE v_venta BIGINT; item JSONB; cot RECORD; rec RECORD;
 v_subtotal NUMERIC:=0; v_cantidad INTEGER; v_monto NUMERIC;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM "VialNex".usuarios u
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles r ON r.id=ur.rol_id
 WHERE u.id=p_usuario AND u.activo AND u.web AND r.nombre IN ('vendedor','administrador')) THEN
  RAISE EXCEPTION 'Usuario sin permiso de venta web'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "VialNex".clientes WHERE id=p_cliente AND activo) THEN
  RAISE EXCEPTION 'Cliente inexistente o inactivo'; END IF;
 IF NULLIF(BTRIM(p_destinatario),'') IS NULL OR NULLIF(BTRIM(p_direccion),'') IS NULL
 OR p_fecha_despacho IS NULL THEN RAISE EXCEPTION 'Destino y fecha obligatorios'; END IF;
 IF p_productos IS NULL OR jsonb_typeof(p_productos)<>'array' THEN
  RAISE EXCEPTION 'Productos debe ser un arreglo'; END IF;
 IF jsonb_array_length(p_productos)=0 THEN RAISE EXCEPTION 'Venta sin productos'; END IF;
 IF p_recargos IS NULL OR jsonb_typeof(p_recargos)<>'array' THEN
  RAISE EXCEPTION 'Recargos debe ser un arreglo'; END IF;
 INSERT INTO "VialNex".ventas(cliente_id,vendedor_id,zona_id,destinatario,direccion_destino,fecha_programada)
 VALUES(p_cliente,p_usuario,p_zona,BTRIM(p_destinatario),BTRIM(p_direccion),p_fecha_despacho)
 RETURNING id INTO v_venta;
 FOR item IN SELECT value FROM jsonb_array_elements(p_productos) LOOP
  IF NULLIF(BTRIM(item->>'descripcion'),'') IS NULL THEN
   RAISE EXCEPTION 'Descripción de producto obligatoria'; END IF;
  v_cantidad:=(item->>'cantidad')::INTEGER;
  SELECT * INTO cot FROM "VialNex".cotizar_producto(p_zona,
   (item->>'largo_cm')::NUMERIC,(item->>'ancho_cm')::NUMERIC,
   (item->>'alto_cm')::NUMERIC,(item->>'peso_kg')::NUMERIC,v_cantidad,CURRENT_DATE);
  INSERT INTO "VialNex".detalle_ventas(venta_id,descripcion,cantidad,largo_cm,ancho_cm,alto_cm,peso_kg,tarifa_id,precio_unitario_aplicado)
  VALUES(v_venta,item->>'descripcion',v_cantidad,(item->>'largo_cm')::NUMERIC,
   (item->>'ancho_cm')::NUMERIC,(item->>'alto_cm')::NUMERIC,(item->>'peso_kg')::NUMERIC,
   cot.tarifa_id,cot.precio_unitario);
  v_subtotal:=v_subtotal+cot.subtotal;
 END LOOP;
 FOR item IN SELECT value FROM jsonb_array_elements(p_recargos) LOOP
  v_cantidad:=(item->>'cantidad')::INTEGER;
  IF v_cantidad IS NULL OR v_cantidad<=0 THEN RAISE EXCEPTION 'Cantidad de recargo inválida'; END IF;
  SELECT * INTO rec FROM "VialNex".tipos_recargo
  WHERE codigo=item->>'codigo' AND activo;
  IF NOT FOUND THEN RAISE EXCEPTION 'Recargo inexistente o inactivo'; END IF;
  v_monto:=ROUND(CASE WHEN rec.modalidad='fijo' THEN rec.valor*v_cantidad
    ELSE v_subtotal*rec.valor/100*v_cantidad END,2);
  INSERT INTO "VialNex".recargos_ventas(venta_id,concepto,monto_aplicado,tipo_recargo_id,cantidad,valor_configurado,modalidad_aplicada)
  VALUES(v_venta,rec.descripcion,v_monto,rec.id,v_cantidad,rec.valor,rec.modalidad);
 END LOOP;
 RETURN v_venta;
END;
$$;


--
-- Name: un_solo_rol_movil(); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".un_solo_rol_movil() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_cuantos INT;
    v_usuario TEXT;
BEGIN
    SELECT COUNT(*) INTO v_cuantos
      FROM "VialNex".usuarios_roles ur
      JOIN "VialNex".roles r ON r.id = ur.rol_id
     WHERE ur.usuario_id = NEW.usuario_id
       AND r.perfil_movil IS NOT NULL;

    IF v_cuantos > 1 THEN
        SELECT nombre INTO v_usuario
          FROM "VialNex".usuarios WHERE id = NEW.usuario_id;
        RAISE EXCEPTION
            'Asignacion multiple: % ya tiene un perfil movil. Solo se permite uno.',
            COALESCE(v_usuario, NEW.usuario_id::text);
    END IF;
    RETURN NULL;
END;
$$;


--
-- Name: validar_integridad_bodega(); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".validar_integridad_bodega() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE v_orden BIGINT; o RECORD;
 v_total BIGINT; v_cargadas BIGINT; v_pendientes BIGINT;
BEGIN
 IF TG_TABLE_NAME='ordenes' THEN v_orden:=NEW.id;
 ELSE v_orden:=NEW.orden_id; END IF;
 SELECT * INTO o FROM "VialNex".ordenes WHERE id=v_orden FOR UPDATE;
 IF NOT FOUND THEN RETURN NULL; END IF;
 IF EXISTS(SELECT 1 FROM "VialNex".posiciones p
 JOIN "VialNex".guias g ON g.id=p.guia_id
 JOIN "VialNex".detalle_ventas d ON d.id=p.detalle_venta_id
 WHERE p.orden_id=v_orden AND (g.orden_id<>p.orden_id OR g.venta_id<>d.venta_id)) THEN
  RAISE EXCEPTION 'Guía, posición y detalle de venta incompatibles';
 END IF;
 IF EXISTS(SELECT 1 FROM "VialNex".posiciones p WHERE p.orden_id=v_orden
 AND p.estado<>'pendiente' AND NOT EXISTS(
 SELECT 1 FROM "VialNex".eventos_carga e WHERE e.posicion_id=p.id AND e.tipo=p.estado)) THEN
  RAISE EXCEPTION 'Estado de posición sin evento correspondiente';
 END IF;
 SELECT COUNT(*),COUNT(*) FILTER(WHERE estado='cargada'),
 COUNT(*) FILTER(WHERE estado='pendiente') INTO v_total,v_cargadas,v_pendientes
 FROM "VialNex".posiciones WHERE orden_id=v_orden;
 IF o.estado='carga_confirmada' AND (v_total=0 OR v_cargadas<>v_total) THEN
  RAISE EXCEPTION 'Carga completa requiere todas las posiciones cargadas';
 END IF;
 IF o.estado='carga_parcial' AND
 (v_cargadas=0 OR v_cargadas=v_total OR v_pendientes>0) THEN
  RAISE EXCEPTION 'Carga parcial requiere productos cargados y exclusiones justificadas';
 END IF;
 IF o.estado IN ('en_ruta','cerrada') AND
 (o.carga_confirmada_en IS NULL OR v_cargadas=0 OR v_pendientes>0) THEN
  RAISE EXCEPTION 'No se permite salir con carga pendiente o sin productos';
 END IF;
 RETURN NULL;
END;
$$;


--
-- Name: validar_pago(); Type: FUNCTION; Schema: VialNex; Owner: -
--

CREATE FUNCTION "VialNex".validar_pago() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE c "VialNex".cargos%ROWTYPE; v_pagado NUMERIC;
BEGIN
 IF NEW.monto IS NULL OR NEW.monto<=0 OR NEW.monto<>ROUND(NEW.monto,2) THEN
  RAISE EXCEPTION 'Monto de pago inválido'; END IF;
 IF NULLIF(BTRIM(NEW.referencia),'') IS NULL OR NULLIF(BTRIM(NEW.medio),'') IS NULL
 OR NEW.pagado_en IS NULL THEN RAISE EXCEPTION 'Referencia, medio y fecha obligatorios'; END IF;
 IF NOT EXISTS(SELECT 1 FROM "VialNex".usuarios u
 JOIN "VialNex".usuarios_roles ur ON ur.usuario_id=u.id
 JOIN "VialNex".roles r ON r.id=ur.rol_id
 WHERE u.id=NEW.registrado_por AND u.activo AND u.web AND r.nombre='administrador') THEN
  RAISE EXCEPTION 'Solo administración registra pagos'; END IF;
 SELECT * INTO c FROM "VialNex".cargos WHERE id=NEW.cargo_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Cargo inexistente'; END IF;
 IF c.aprobado_en IS NULL OR c.aprobado_por IS NULL THEN
  RAISE EXCEPTION 'Cargo pendiente de aprobación'; END IF;
 IF EXISTS(SELECT 1 FROM "VialNex".pagos WHERE cargo_id=NEW.cargo_id
 AND LOWER(BTRIM(referencia))=LOWER(BTRIM(NEW.referencia))) THEN
  RAISE EXCEPTION 'Referencia de pago ya registrada para este cargo'; END IF;
 SELECT COALESCE(SUM(monto),0) INTO v_pagado FROM "VialNex".pagos WHERE cargo_id=NEW.cargo_id;
 IF NEW.monto>c.monto-v_pagado THEN RAISE EXCEPTION 'Pago supera el saldo pendiente'; END IF;
 NEW.referencia:=BTRIM(NEW.referencia); NEW.medio:=BTRIM(NEW.medio);
 RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: cambios_ruta; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".cambios_ruta (
    id bigint NOT NULL,
    orden_id bigint NOT NULL,
    ruta_anterior_id bigint,
    ruta_nueva_id bigint NOT NULL,
    cambiado_por bigint NOT NULL,
    motivo text NOT NULL,
    cambiado_en timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT cambios_ruta_check CHECK (((ruta_anterior_id IS NULL) OR (ruta_anterior_id <> ruta_nueva_id))),
    CONSTRAINT cambios_ruta_motivo_check CHECK ((btrim(motivo) <> ''::text))
);


--
-- Name: cambios_ruta_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".cambios_ruta ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".cambios_ruta_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: cargos; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".cargos (
    id bigint NOT NULL,
    venta_id bigint NOT NULL,
    entrega_id bigint,
    concepto character varying(100) NOT NULL,
    monto numeric(14,2) NOT NULL,
    aprobado_por bigint,
    aprobado_en timestamp with time zone,
    creado_en timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    creado_por bigint,
    justificacion text,
    CONSTRAINT cargos_monto_check CHECK ((monto >= (0)::numeric))
);


--
-- Name: cargos_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".cargos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".cargos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: clientes; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".clientes (
    id bigint NOT NULL,
    nombre character varying(150) NOT NULL,
    rut character varying(20),
    email character varying(150),
    telefono character varying(30),
    activo boolean DEFAULT true NOT NULL,
    creado_en timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: clientes_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".clientes ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".clientes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: comunas; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".comunas (
    id bigint NOT NULL,
    nombre character varying(100) NOT NULL,
    region character varying(100) NOT NULL,
    zona_id bigint NOT NULL,
    activa boolean DEFAULT true NOT NULL,
    nombre_normalizado text GENERATED ALWAYS AS (lower(translate(btrim((nombre)::text), 'ÁÉÍÓÚÜÑáéíóúüñ'::text, 'AEIOUUNaeiouun'::text))) STORED,
    region_normalizada text GENERATED ALWAYS AS (lower(translate(btrim((region)::text), 'ÁÉÍÓÚÜÑáéíóúüñ'::text, 'AEIOUUNaeiouun'::text))) STORED,
    CONSTRAINT comunas_nombre_check CHECK ((btrim((nombre)::text) <> ''::text)),
    CONSTRAINT comunas_region_check CHECK ((btrim((region)::text) <> ''::text))
);


--
-- Name: comunas_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".comunas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".comunas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: costos_vehiculo; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".costos_vehiculo (
    id bigint NOT NULL,
    vehiculo_id bigint NOT NULL,
    fecha date NOT NULL,
    concepto character varying(100) NOT NULL,
    monto numeric(14,2) NOT NULL,
    CONSTRAINT costos_vehiculo_monto_check CHECK ((monto >= (0)::numeric))
);


--
-- Name: costos_vehiculo_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".costos_vehiculo ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".costos_vehiculo_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: detalle_ventas; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".detalle_ventas (
    id bigint NOT NULL,
    venta_id bigint NOT NULL,
    descripcion character varying(200) NOT NULL,
    cantidad integer NOT NULL,
    largo_cm numeric(10,2) NOT NULL,
    ancho_cm numeric(10,2) NOT NULL,
    alto_cm numeric(10,2) NOT NULL,
    peso_kg numeric(10,2) NOT NULL,
    tarifa_id bigint NOT NULL,
    precio_unitario_aplicado numeric(14,2) NOT NULL,
    CONSTRAINT detalle_ventas_alto_cm_check CHECK ((alto_cm > (0)::numeric)),
    CONSTRAINT detalle_ventas_ancho_cm_check CHECK ((ancho_cm > (0)::numeric)),
    CONSTRAINT detalle_ventas_cantidad_check CHECK ((cantidad > 0)),
    CONSTRAINT detalle_ventas_largo_cm_check CHECK ((largo_cm > (0)::numeric)),
    CONSTRAINT detalle_ventas_peso_kg_check CHECK ((peso_kg > (0)::numeric)),
    CONSTRAINT detalle_ventas_precio_unitario_aplicado_check CHECK ((precio_unitario_aplicado >= (0)::numeric))
);


--
-- Name: detalle_ventas_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".detalle_ventas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".detalle_ventas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: documentos; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".documentos (
    id bigint NOT NULL,
    vehiculo_id bigint,
    personal_id bigint,
    guia_id bigint,
    tipo character varying(80) NOT NULL,
    archivo_url text NOT NULL,
    vence_en date,
    CONSTRAINT documentos_check CHECK ((num_nonnulls(vehiculo_id, personal_id, guia_id) = 1))
);


--
-- Name: documentos_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".documentos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".documentos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: entregas; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".entregas (
    id bigint NOT NULL,
    parada_id bigint NOT NULL,
    registrada_por bigint NOT NULL,
    resultado character varying(20) NOT NULL,
    motivo_id bigint,
    ocurrido_en timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    foto_url text,
    firma_url text,
    observacion text,
    CONSTRAINT entregas_check CHECK (((((resultado)::text = 'fallida'::text) AND (motivo_id IS NOT NULL)) OR (((resultado)::text = 'entregada'::text) AND (motivo_id IS NULL)))),
    CONSTRAINT entregas_resultado_check CHECK (((resultado)::text = ANY ((ARRAY['entregada'::character varying, 'fallida'::character varying])::text[])))
);


--
-- Name: entregas_bultos; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".entregas_bultos (
    id bigint NOT NULL,
    entrega_id bigint NOT NULL,
    posicion_id bigint NOT NULL,
    resultado character varying(20) NOT NULL,
    motivo_id bigint,
    CONSTRAINT vn_entrega_bulto_motivo CHECK (((((resultado)::text = 'devuelta'::text) AND (motivo_id IS NOT NULL)) OR (((resultado)::text = 'entregada'::text) AND (motivo_id IS NULL)))),
    CONSTRAINT vn_entrega_bulto_resultado CHECK (((resultado)::text = ANY ((ARRAY['entregada'::character varying, 'devuelta'::character varying])::text[])))
);


--
-- Name: TABLE entregas_bultos; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON TABLE "VialNex".entregas_bultos IS 'Que paso con cada bulto en una entrega. Inmutable, como eventos_carga.';


--
-- Name: entregas_bultos_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".entregas_bultos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".entregas_bultos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: entregas_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".entregas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".entregas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: eventos_carga; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".eventos_carga (
    id bigint NOT NULL,
    posicion_id bigint NOT NULL,
    usuario_id bigint NOT NULL,
    tipo character varying(30) NOT NULL,
    ocurrido_en timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    evidencia_url text,
    observacion text,
    CONSTRAINT eventos_carga_check CHECK ((((tipo)::text <> 'danada'::text) OR (NULLIF(btrim(evidencia_url), ''::text) IS NOT NULL))),
    CONSTRAINT eventos_carga_tipo_check CHECK (((tipo)::text = ANY ((ARRAY['cargada'::character varying, 'sin_stock'::character varying, 'danada'::character varying, 'revertida'::character varying])::text[])))
);


--
-- Name: eventos_carga_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".eventos_carga ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".eventos_carga_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: evidencias; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".evidencias (
    id bigint NOT NULL,
    evento_id bigint NOT NULL,
    url text NOT NULL,
    orden smallint DEFAULT 1 NOT NULL,
    subida_por bigint,
    subida_en timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT evidencias_orden_check CHECK ((orden > 0)),
    CONSTRAINT evidencias_url_check CHECK ((btrim(url) <> ''::text))
);


--
-- Name: evidencias_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".evidencias ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".evidencias_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: facturas; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".facturas (
    id bigint NOT NULL,
    cliente_id bigint NOT NULL,
    referencia character varying(80) NOT NULL,
    emitida_en date NOT NULL,
    vence_en date,
    estado character varying(20) DEFAULT 'borrador'::character varying NOT NULL,
    archivo_url text,
    CONSTRAINT facturas_check CHECK (((vence_en IS NULL) OR (vence_en >= emitida_en))),
    CONSTRAINT facturas_estado_check CHECK (((estado)::text = ANY ((ARRAY['borrador'::character varying, 'registrada'::character varying, 'anulada'::character varying])::text[])))
);


--
-- Name: facturas_cargos; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".facturas_cargos (
    factura_id bigint NOT NULL,
    cargo_id bigint NOT NULL
);


--
-- Name: facturas_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".facturas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".facturas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: guias; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".guias (
    id bigint NOT NULL,
    numero character varying(40) NOT NULL,
    orden_id bigint NOT NULL,
    venta_id bigint NOT NULL,
    archivo_url text
);


--
-- Name: guias_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".guias ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".guias_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: hitos_ruta; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".hitos_ruta (
    id bigint NOT NULL,
    ruta_id bigint NOT NULL,
    registrado_por bigint NOT NULL,
    tipo character varying(40) NOT NULL,
    ocurrido_en timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    observacion text,
    evidencia_url text,
    CONSTRAINT hitos_ruta_tipo_check CHECK (((tipo)::text = ANY ((ARRAY['salida'::character varying, 'llegada'::character varying, 'retorno'::character varying, 'incidencia'::character varying, 'cierre'::character varying])::text[])))
);


--
-- Name: hitos_ruta_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".hitos_ruta ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".hitos_ruta_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: mantenimientos; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".mantenimientos (
    id bigint NOT NULL,
    vehiculo_id bigint NOT NULL,
    descripcion text NOT NULL,
    fecha_programada date NOT NULL,
    fecha_realizada date,
    kilometraje numeric(12,2),
    costo numeric(14,2) DEFAULT 0 NOT NULL,
    CONSTRAINT mantenimientos_costo_check CHECK ((costo >= (0)::numeric)),
    CONSTRAINT mantenimientos_kilometraje_check CHECK ((kilometraje >= (0)::numeric))
);


--
-- Name: mantenimientos_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".mantenimientos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".mantenimientos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: motivos_entrega_fallida; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".motivos_entrega_fallida (
    id bigint NOT NULL,
    nombre character varying(100) NOT NULL,
    responsabilidad character varying(30) NOT NULL,
    CONSTRAINT motivos_entrega_fallida_responsabilidad_check CHECK (((responsabilidad)::text = ANY ((ARRAY['cliente'::character varying, 'transportista'::character varying, 'fuerza_mayor'::character varying])::text[])))
);


--
-- Name: motivos_entrega_fallida_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".motivos_entrega_fallida ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".motivos_entrega_fallida_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: orden_estados; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".orden_estados (
    id bigint NOT NULL,
    orden_id bigint NOT NULL,
    estado character varying(30) NOT NULL,
    estado_previo character varying(30),
    cambiado_por bigint,
    usuario_bd text DEFAULT CURRENT_USER NOT NULL,
    cambiado_en timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    origen character varying(30) NOT NULL,
    observacion text,
    CONSTRAINT orden_estados_check CHECK (((estado_previo IS NULL) OR ((estado_previo)::text <> (estado)::text))),
    CONSTRAINT orden_estados_origen_check CHECK (((origen)::text = ANY ((ARRAY['creacion'::character varying, 'transicion'::character varying, 'linea_base'::character varying])::text[])))
);


--
-- Name: orden_estados_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".orden_estados ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".orden_estados_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ordenes; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".ordenes (
    id bigint NOT NULL,
    codigo character varying(30) NOT NULL,
    ruta_id bigint,
    creada_por bigint NOT NULL,
    estado character varying(30) DEFAULT 'en_bodega'::character varying NOT NULL,
    creada_en timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    carga_confirmada_en timestamp with time zone,
    carga_confirmada_por bigint,
    orden_origen_id bigint,
    observaciones text,
    asignada_a bigint,
    asignada_en timestamp with time zone,
    asignada_por bigint,
    vehiculo_carga_id bigint,
    CONSTRAINT vn_orden_estado CHECK (((estado)::text = ANY ((ARRAY['en_bodega'::character varying, 'carga_confirmada'::character varying, 'carga_parcial'::character varying, 'en_ruta'::character varying, 'cerrada'::character varying, 'cancelada'::character varying, 'por_revisar'::character varying])::text[]))),
    CONSTRAINT vn_orden_origen_distinta CHECK ((orden_origen_id <> id))
);


--
-- Name: COLUMN ordenes.asignada_a; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON COLUMN "VialNex".ordenes.asignada_a IS 'Bodeguero responsable de cargar esta orden. Solo el (o un administrador) puede escanear sus posiciones.';


--
-- Name: COLUMN ordenes.vehiculo_carga_id; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON COLUMN "VialNex".ordenes.vehiculo_carga_id IS 'Vehiculo en que se carga esta orden. Se elige al empezar la carga, no al cerrarla. Distinto de rutas.vehiculo_id (el planificado).';


--
-- Name: ordenes_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".ordenes ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".ordenes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: pagos; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".pagos (
    id bigint NOT NULL,
    cargo_id bigint NOT NULL,
    monto numeric(14,2) NOT NULL,
    pagado_en timestamp with time zone NOT NULL,
    medio character varying(50) NOT NULL,
    referencia character varying(100),
    registrado_por bigint,
    CONSTRAINT pagos_monto_check CHECK ((monto > (0)::numeric))
);


--
-- Name: pagos_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".pagos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".pagos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: paradas_ruta; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".paradas_ruta (
    id bigint NOT NULL,
    ruta_id bigint NOT NULL,
    guia_id bigint NOT NULL,
    secuencia integer NOT NULL,
    CONSTRAINT paradas_ruta_secuencia_check CHECK ((secuencia > 0))
);


--
-- Name: paradas_ruta_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".paradas_ruta ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".paradas_ruta_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: personal; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".personal (
    id bigint NOT NULL,
    usuario_id bigint,
    nombre character varying(150) NOT NULL,
    rut character varying(20),
    cargo character varying(80) NOT NULL,
    licencia character varying(30),
    licencia_vence date,
    activo boolean DEFAULT true NOT NULL
);


--
-- Name: personal_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".personal ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".personal_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: posiciones; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".posiciones (
    id bigint NOT NULL,
    orden_id bigint NOT NULL,
    guia_id bigint NOT NULL,
    detalle_venta_id bigint NOT NULL,
    codigo_barras character varying(80) NOT NULL,
    cantidad_bultos integer NOT NULL,
    estado character varying(30) DEFAULT 'pendiente'::character varying NOT NULL,
    foto_url text,
    marcada_en timestamp with time zone,
    marcada_por bigint,
    observaciones text,
    CONSTRAINT posiciones_cantidad_bultos_check CHECK ((cantidad_bultos > 0)),
    CONSTRAINT posiciones_estado_check CHECK (((estado)::text = ANY ((ARRAY['pendiente'::character varying, 'cargada'::character varying, 'sin_stock'::character varying, 'danada'::character varying])::text[])))
);


--
-- Name: posiciones_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".posiciones ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".posiciones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recargos_ventas; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".recargos_ventas (
    id bigint NOT NULL,
    venta_id bigint NOT NULL,
    concepto character varying(100) NOT NULL,
    monto_aplicado numeric(14,2) NOT NULL,
    tipo_recargo_id bigint,
    cantidad integer,
    valor_configurado numeric(14,4),
    modalidad_aplicada character varying(15),
    CONSTRAINT recargos_ventas_cantidad_check CHECK ((cantidad > 0)),
    CONSTRAINT recargos_ventas_monto_aplicado_check CHECK ((monto_aplicado >= (0)::numeric))
);


--
-- Name: recargos_ventas_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".recargos_ventas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".recargos_ventas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recuperacion_clave; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".recuperacion_clave (
    id bigint NOT NULL,
    usuario_id bigint NOT NULL,
    codigo_hash text NOT NULL,
    tipo character varying(20) NOT NULL,
    expira_en timestamp with time zone NOT NULL,
    usado_en timestamp with time zone,
    intentos smallint DEFAULT 0 NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    ip character varying(45),
    CONSTRAINT recuperacion_clave_tipo_check CHECK (((tipo)::text = ANY ((ARRAY['primera'::character varying, 'recuperacion'::character varying])::text[])))
);


--
-- Name: TABLE recuperacion_clave; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON TABLE "VialNex".recuperacion_clave IS 'Codigos de un solo uso para crear o recuperar la contrasena';


--
-- Name: recuperacion_clave_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".recuperacion_clave ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".recuperacion_clave_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: roles; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".roles (
    id bigint NOT NULL,
    nombre character varying(50) NOT NULL,
    descripcion character varying(250),
    web boolean DEFAULT true NOT NULL,
    movil boolean DEFAULT false NOT NULL,
    perfil_movil character varying(20),
    modulos text[] DEFAULT '{}'::text[] NOT NULL,
    CONSTRAINT vn_rol_modulos_web CHECK ((web OR (cardinality(modulos) = 0))),
    CONSTRAINT vn_rol_perfil_movil CHECK ((((perfil_movil IS NULL) OR ((perfil_movil)::text = ANY ((ARRAY['bodega'::character varying, 'transporte'::character varying])::text[]))) AND ((perfil_movil IS NULL) OR movil)))
);


--
-- Name: COLUMN roles.web; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON COLUMN "VialNex".roles.web IS 'El rol sirve en la pagina web';


--
-- Name: COLUMN roles.movil; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON COLUMN "VialNex".roles.movil IS 'El rol permite entrar a la aplicacion movil';


--
-- Name: COLUMN roles.perfil_movil; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON COLUMN "VialNex".roles.perfil_movil IS 'Pantalla de inicio en el telefono. NULL = el rol no define pantalla.';


--
-- Name: COLUMN roles.modulos; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON COLUMN "VialNex".roles.modulos IS 'Modulos de la pagina web que abre este rol. Los nombres los define el front; la base solo los guarda.';


--
-- Name: roles_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".roles ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: rutas; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".rutas (
    id bigint NOT NULL,
    codigo character varying(30) NOT NULL,
    vehiculo_id bigint NOT NULL,
    conductor_id bigint NOT NULL,
    fecha date NOT NULL,
    salida_en timestamp with time zone,
    cierre_en timestamp with time zone,
    estado character varying(30) DEFAULT 'planificada'::character varying NOT NULL,
    CONSTRAINT rutas_check CHECK (((cierre_en IS NULL) OR ((salida_en IS NOT NULL) AND (cierre_en >= salida_en)))),
    CONSTRAINT rutas_estado_check CHECK (((estado)::text = ANY ((ARRAY['planificada'::character varying, 'en_ruta'::character varying, 'cerrada'::character varying, 'cancelada'::character varying])::text[])))
);


--
-- Name: rutas_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".rutas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".rutas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tarifas; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".tarifas (
    id bigint NOT NULL,
    zona_id bigint NOT NULL,
    tramo_id bigint NOT NULL,
    monto numeric(14,2) NOT NULL,
    vigente_desde date NOT NULL,
    vigente_hasta date,
    CONSTRAINT tarifas_check CHECK (((vigente_hasta IS NULL) OR (vigente_hasta >= vigente_desde))),
    CONSTRAINT tarifas_monto_check CHECK ((monto >= (0)::numeric))
);


--
-- Name: tarifas_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".tarifas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".tarifas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tipos_recargo; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".tipos_recargo (
    id bigint NOT NULL,
    codigo character varying(50) NOT NULL,
    descripcion character varying(150) NOT NULL,
    modalidad character varying(15) NOT NULL,
    valor numeric(14,4) NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    CONSTRAINT tipos_recargo_modalidad_check CHECK (((modalidad)::text = ANY ((ARRAY['fijo'::character varying, 'porcentaje'::character varying])::text[]))),
    CONSTRAINT tipos_recargo_valor_check CHECK ((valor >= (0)::numeric))
);


--
-- Name: tipos_recargo_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".tipos_recargo ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".tipos_recargo_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tramos; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".tramos (
    id bigint NOT NULL,
    codigo character varying(10) NOT NULL,
    lado_max_cm numeric(10,2),
    peso_max_kg numeric(10,2),
    prioridad integer NOT NULL,
    CONSTRAINT tramos_lado_max_cm_check CHECK ((lado_max_cm > (0)::numeric)),
    CONSTRAINT tramos_peso_max_kg_check CHECK ((peso_max_kg > (0)::numeric))
);


--
-- Name: tramos_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".tramos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".tramos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ubicaciones_ruta; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".ubicaciones_ruta (
    id bigint NOT NULL,
    ruta_id bigint NOT NULL,
    registrado_por bigint NOT NULL,
    latitud numeric(10,7) NOT NULL,
    longitud numeric(10,7) NOT NULL,
    precision_m numeric(10,2),
    capturada_en timestamp with time zone NOT NULL,
    recibida_en timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT ubicaciones_ruta_latitud_check CHECK (((latitud >= ('-90'::integer)::numeric) AND (latitud <= (90)::numeric))),
    CONSTRAINT ubicaciones_ruta_longitud_check CHECK (((longitud >= ('-180'::integer)::numeric) AND (longitud <= (180)::numeric))),
    CONSTRAINT ubicaciones_ruta_precision_m_check CHECK ((precision_m >= (0)::numeric))
);


--
-- Name: ubicaciones_ruta_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".ubicaciones_ruta ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".ubicaciones_ruta_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: usuarios; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".usuarios (
    id bigint NOT NULL,
    nombre character varying(150) NOT NULL,
    email character varying(150) NOT NULL,
    password_hash text NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    creado_en timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    telefono character varying,
    web boolean DEFAULT true NOT NULL,
    movil boolean DEFAULT false NOT NULL,
    ultimo_acceso_en timestamp with time zone,
    clave_cambiada_en timestamp with time zone,
    rut character varying(20),
    modificado_en timestamp with time zone,
    modificado_por bigint
);


--
-- Name: COLUMN usuarios.web; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON COLUMN "VialNex".usuarios.web IS 'TRUE si el usuario puede iniciar sesion en la pagina web';


--
-- Name: COLUMN usuarios.movil; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON COLUMN "VialNex".usuarios.movil IS 'TRUE si el usuario puede iniciar sesion en la aplicacion movil';


--
-- Name: COLUMN usuarios.clave_cambiada_en; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON COLUMN "VialNex".usuarios.clave_cambiada_en IS 'Ultimo cambio de contrasena. Los tokens emitidos antes se rechazan.';


--
-- Name: COLUMN usuarios.rut; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON COLUMN "VialNex".usuarios.rut IS 'Con puntos y guion, como se escribe en Chile';


--
-- Name: usuarios_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".usuarios ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".usuarios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: usuarios_roles; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".usuarios_roles (
    usuario_id bigint NOT NULL,
    rol_id bigint NOT NULL
);


--
-- Name: v_avance_bodega; Type: VIEW; Schema: VialNex; Owner: -
--

CREATE VIEW "VialNex".v_avance_bodega AS
 SELECT o.id AS orden_id,
    o.codigo,
    o.estado,
    count(p.id) AS posiciones,
    count(p.id) FILTER (WHERE ((p.estado)::text = 'cargada'::text)) AS cargadas,
    count(p.id) FILTER (WHERE ((p.estado)::text = 'pendiente'::text)) AS pendientes,
    count(p.id) FILTER (WHERE ((p.estado)::text = ANY ((ARRAY['sin_stock'::character varying, 'danada'::character varying])::text[]))) AS excluidas,
    COALESCE(sum(p.cantidad_bultos), (0)::bigint) AS bultos,
    COALESCE(sum(p.cantidad_bultos) FILTER (WHERE ((p.estado)::text = 'cargada'::text)), (0)::bigint) AS bultos_cargados
   FROM ("VialNex".ordenes o
     LEFT JOIN "VialNex".posiciones p ON ((p.orden_id = o.id)))
  GROUP BY o.id, o.codigo, o.estado;


--
-- Name: v_cobranza; Type: VIEW; Schema: VialNex; Owner: -
--

CREATE VIEW "VialNex".v_cobranza AS
 SELECT c.id AS cargo_id,
    c.venta_id,
    c.concepto,
    c.monto,
    c.aprobado_en,
    COALESCE(p.pagado, (0)::numeric) AS pagado,
    (c.monto - COALESCE(p.pagado, (0)::numeric)) AS saldo
   FROM ("VialNex".cargos c
     LEFT JOIN ( SELECT pagos.cargo_id,
            sum(pagos.monto) AS pagado
           FROM "VialNex".pagos
          GROUP BY pagos.cargo_id) p ON ((p.cargo_id = c.id)));


--
-- Name: v_estado_cobranza; Type: VIEW; Schema: VialNex; Owner: -
--

CREATE VIEW "VialNex".v_estado_cobranza AS
 SELECT cargo_id,
    venta_id,
    concepto,
    monto,
    aprobado_en,
    pagado,
    saldo,
        CASE
            WHEN (aprobado_en IS NULL) THEN 'pendiente_aprobacion'::text
            WHEN (saldo <= (0)::numeric) THEN 'pagado'::text
            WHEN (pagado > (0)::numeric) THEN 'abonado'::text
            ELSE 'pendiente_pago'::text
        END AS estado_cobro
   FROM "VialNex".v_cobranza c;


--
-- Name: v_resultados_paradas; Type: VIEW; Schema: VialNex; Owner: -
--

CREATE VIEW "VialNex".v_resultados_paradas AS
 SELECT p.id AS parada_id,
    p.ruta_id,
    p.guia_id,
    p.secuencia,
    e.id AS ultimo_intento_id,
    e.resultado,
    e.motivo_id,
    e.ocurrido_en,
    COALESCE(e.resultado, 'pendiente'::character varying) AS estado_entrega
   FROM ("VialNex".paradas_ruta p
     LEFT JOIN LATERAL ( SELECT entregas.id,
            entregas.parada_id,
            entregas.registrada_por,
            entregas.resultado,
            entregas.motivo_id,
            entregas.ocurrido_en,
            entregas.foto_url,
            entregas.firma_url,
            entregas.observacion
           FROM "VialNex".entregas
          WHERE (entregas.parada_id = p.id)
          ORDER BY entregas.id DESC
         LIMIT 1) e ON (true));


--
-- Name: ventas; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".ventas (
    id bigint NOT NULL,
    cliente_id bigint NOT NULL,
    vendedor_id bigint NOT NULL,
    zona_id bigint NOT NULL,
    destinatario character varying(150) NOT NULL,
    telefono_destino character varying(30),
    direccion_destino text NOT NULL,
    fecha_programada date NOT NULL,
    estado character varying(30) DEFAULT 'registrada'::character varying NOT NULL,
    creado_en timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    comuna_destino character varying(100),
    ventana_desde time without time zone,
    ventana_hasta time without time zone,
    observaciones text,
    comuna_id bigint,
    CONSTRAINT ventas_estado_check CHECK (((estado)::text = ANY ((ARRAY['registrada'::character varying, 'confirmada'::character varying, 'anulada'::character varying])::text[])))
);


--
-- Name: v_totales_ventas; Type: VIEW; Schema: VialNex; Owner: -
--

CREATE VIEW "VialNex".v_totales_ventas AS
 SELECT v.id AS venta_id,
    COALESCE(d.subtotal, (0)::numeric) AS subtotal,
    COALESCE(r.recargos, (0)::numeric) AS recargos,
    (COALESCE(d.subtotal, (0)::numeric) + COALESCE(r.recargos, (0)::numeric)) AS total
   FROM (("VialNex".ventas v
     LEFT JOIN ( SELECT detalle_ventas.venta_id,
            sum(((detalle_ventas.cantidad)::numeric * detalle_ventas.precio_unitario_aplicado)) AS subtotal
           FROM "VialNex".detalle_ventas
          GROUP BY detalle_ventas.venta_id) d ON ((d.venta_id = v.id)))
     LEFT JOIN ( SELECT recargos_ventas.venta_id,
            sum(recargos_ventas.monto_aplicado) AS recargos
           FROM "VialNex".recargos_ventas
          GROUP BY recargos_ventas.venta_id) r ON ((r.venta_id = v.id)));


--
-- Name: vehiculos; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".vehiculos (
    id bigint NOT NULL,
    patente character varying(15) NOT NULL,
    marca character varying(80),
    modelo character varying(80),
    kilometraje numeric(12,2) DEFAULT 0 NOT NULL,
    estado character varying(30) DEFAULT 'operativo'::character varying NOT NULL,
    capacidad_kg numeric(12,2),
    capacidad_m3 numeric(12,3),
    largo_util_cm numeric,
    ancho_util_cm numeric,
    alto_util_cm numeric,
    CONSTRAINT vehiculos_capacidad_kg_check CHECK ((capacidad_kg > (0)::numeric)),
    CONSTRAINT vehiculos_capacidad_m3_check CHECK ((capacidad_m3 > (0)::numeric)),
    CONSTRAINT vehiculos_estado_check CHECK (((estado)::text = ANY ((ARRAY['operativo'::character varying, 'mantenimiento'::character varying, 'fuera_servicio'::character varying])::text[]))),
    CONSTRAINT vehiculos_kilometraje_check CHECK ((kilometraje >= (0)::numeric)),
    CONSTRAINT vn_vehiculo_dimensiones CHECK ((((largo_util_cm IS NULL) OR (largo_util_cm > (0)::numeric)) AND ((ancho_util_cm IS NULL) OR (ancho_util_cm > (0)::numeric)) AND ((alto_util_cm IS NULL) OR (alto_util_cm > (0)::numeric))))
);


--
-- Name: COLUMN vehiculos.largo_util_cm; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON COLUMN "VialNex".vehiculos.largo_util_cm IS 'Medida interior del espacio de carga, en cm. No la exterior del vehiculo.';


--
-- Name: COLUMN vehiculos.ancho_util_cm; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON COLUMN "VialNex".vehiculos.ancho_util_cm IS 'Ancho interior útil de carga en centímetros.';


--
-- Name: COLUMN vehiculos.alto_util_cm; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON COLUMN "VialNex".vehiculos.alto_util_cm IS 'Altura interior útil de carga en centímetros.';


--
-- Name: vehiculos_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".vehiculos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".vehiculos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ventas_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".ventas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".ventas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: vw_carga_vehiculo; Type: VIEW; Schema: VialNex; Owner: -
--

CREATE VIEW "VialNex".vw_carga_vehiculo AS
 SELECT v.id AS vehiculo_id,
    v.patente,
    v.estado AS estado_vehiculo,
    v.capacidad_kg,
    v.capacidad_m3,
    count(DISTINCT o.id) FILTER (WHERE (p.id IS NOT NULL)) AS ordenes_a_bordo,
    COALESCE(sum((d.peso_kg * (d.cantidad)::numeric)), (0)::numeric) AS peso_kg,
    string_agg(DISTINCT (o.codigo)::text, ', '::text) FILTER (WHERE (p.id IS NOT NULL)) AS codigos
   FROM ((("VialNex".vehiculos v
     LEFT JOIN "VialNex".ordenes o ON ((o.vehiculo_carga_id = v.id)))
     LEFT JOIN "VialNex".posiciones p ON (((p.orden_id = o.id) AND ((p.estado)::text = 'cargada'::text) AND (NOT (EXISTS ( SELECT 1
           FROM "VialNex".entregas_bultos eb
          WHERE (eb.posicion_id = p.id)))))))
     LEFT JOIN "VialNex".detalle_ventas d ON ((d.id = p.detalle_venta_id)))
  GROUP BY v.id, v.patente, v.estado, v.capacidad_kg, v.capacidad_m3;


--
-- Name: VIEW vw_carga_vehiculo; Type: COMMENT; Schema: VialNex; Owner: -
--

COMMENT ON VIEW "VialNex".vw_carga_vehiculo IS 'Que lleva encima cada camion ahora. Baja con cada bulto entregado.';


--
-- Name: zonas; Type: TABLE; Schema: VialNex; Owner: -
--

CREATE TABLE "VialNex".zonas (
    id bigint NOT NULL,
    nombre character varying(80) NOT NULL
);


--
-- Name: zonas_id_seq; Type: SEQUENCE; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".zonas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "VialNex".zonas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: cambios_ruta cambios_ruta_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".cambios_ruta
    ADD CONSTRAINT cambios_ruta_pkey PRIMARY KEY (id);


--
-- Name: cargos cargos_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".cargos
    ADD CONSTRAINT cargos_pkey PRIMARY KEY (id);


--
-- Name: clientes clientes_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".clientes
    ADD CONSTRAINT clientes_pkey PRIMARY KEY (id);


--
-- Name: comunas comunas_id_zona_id_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".comunas
    ADD CONSTRAINT comunas_id_zona_id_key UNIQUE (id, zona_id);


--
-- Name: comunas comunas_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".comunas
    ADD CONSTRAINT comunas_pkey PRIMARY KEY (id);


--
-- Name: comunas comunas_region_normalizada_nombre_normalizado_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".comunas
    ADD CONSTRAINT comunas_region_normalizada_nombre_normalizado_key UNIQUE (region_normalizada, nombre_normalizado);


--
-- Name: costos_vehiculo costos_vehiculo_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".costos_vehiculo
    ADD CONSTRAINT costos_vehiculo_pkey PRIMARY KEY (id);


--
-- Name: detalle_ventas detalle_ventas_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".detalle_ventas
    ADD CONSTRAINT detalle_ventas_pkey PRIMARY KEY (id);


--
-- Name: documentos documentos_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".documentos
    ADD CONSTRAINT documentos_pkey PRIMARY KEY (id);


--
-- Name: entregas_bultos entregas_bultos_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".entregas_bultos
    ADD CONSTRAINT entregas_bultos_pkey PRIMARY KEY (id);


--
-- Name: entregas entregas_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".entregas
    ADD CONSTRAINT entregas_pkey PRIMARY KEY (id);


--
-- Name: eventos_carga eventos_carga_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".eventos_carga
    ADD CONSTRAINT eventos_carga_pkey PRIMARY KEY (id);


--
-- Name: evidencias evidencias_evento_id_orden_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".evidencias
    ADD CONSTRAINT evidencias_evento_id_orden_key UNIQUE (evento_id, orden);


--
-- Name: evidencias evidencias_evento_id_url_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".evidencias
    ADD CONSTRAINT evidencias_evento_id_url_key UNIQUE (evento_id, url);


--
-- Name: evidencias evidencias_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".evidencias
    ADD CONSTRAINT evidencias_pkey PRIMARY KEY (id);


--
-- Name: facturas_cargos facturas_cargos_cargo_id_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".facturas_cargos
    ADD CONSTRAINT facturas_cargos_cargo_id_key UNIQUE (cargo_id);


--
-- Name: facturas_cargos facturas_cargos_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".facturas_cargos
    ADD CONSTRAINT facturas_cargos_pkey PRIMARY KEY (factura_id, cargo_id);


--
-- Name: facturas facturas_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".facturas
    ADD CONSTRAINT facturas_pkey PRIMARY KEY (id);


--
-- Name: facturas facturas_referencia_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".facturas
    ADD CONSTRAINT facturas_referencia_key UNIQUE (referencia);


--
-- Name: guias guias_id_orden_id_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".guias
    ADD CONSTRAINT guias_id_orden_id_key UNIQUE (id, orden_id);


--
-- Name: guias guias_numero_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".guias
    ADD CONSTRAINT guias_numero_key UNIQUE (numero);


--
-- Name: guias guias_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".guias
    ADD CONSTRAINT guias_pkey PRIMARY KEY (id);


--
-- Name: hitos_ruta hitos_ruta_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".hitos_ruta
    ADD CONSTRAINT hitos_ruta_pkey PRIMARY KEY (id);


--
-- Name: mantenimientos mantenimientos_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".mantenimientos
    ADD CONSTRAINT mantenimientos_pkey PRIMARY KEY (id);


--
-- Name: motivos_entrega_fallida motivos_entrega_fallida_nombre_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".motivos_entrega_fallida
    ADD CONSTRAINT motivos_entrega_fallida_nombre_key UNIQUE (nombre);


--
-- Name: motivos_entrega_fallida motivos_entrega_fallida_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".motivos_entrega_fallida
    ADD CONSTRAINT motivos_entrega_fallida_pkey PRIMARY KEY (id);


--
-- Name: orden_estados orden_estados_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".orden_estados
    ADD CONSTRAINT orden_estados_pkey PRIMARY KEY (id);


--
-- Name: ordenes ordenes_codigo_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ordenes
    ADD CONSTRAINT ordenes_codigo_key UNIQUE (codigo);


--
-- Name: ordenes ordenes_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ordenes
    ADD CONSTRAINT ordenes_pkey PRIMARY KEY (id);


--
-- Name: pagos pagos_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".pagos
    ADD CONSTRAINT pagos_pkey PRIMARY KEY (id);


--
-- Name: paradas_ruta paradas_ruta_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".paradas_ruta
    ADD CONSTRAINT paradas_ruta_pkey PRIMARY KEY (id);


--
-- Name: paradas_ruta paradas_ruta_ruta_id_guia_id_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".paradas_ruta
    ADD CONSTRAINT paradas_ruta_ruta_id_guia_id_key UNIQUE (ruta_id, guia_id);


--
-- Name: paradas_ruta paradas_ruta_ruta_id_secuencia_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".paradas_ruta
    ADD CONSTRAINT paradas_ruta_ruta_id_secuencia_key UNIQUE (ruta_id, secuencia);


--
-- Name: personal personal_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".personal
    ADD CONSTRAINT personal_pkey PRIMARY KEY (id);


--
-- Name: personal personal_rut_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".personal
    ADD CONSTRAINT personal_rut_key UNIQUE (rut);


--
-- Name: personal personal_usuario_id_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".personal
    ADD CONSTRAINT personal_usuario_id_key UNIQUE (usuario_id);


--
-- Name: posiciones posiciones_orden_id_codigo_barras_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".posiciones
    ADD CONSTRAINT posiciones_orden_id_codigo_barras_key UNIQUE (orden_id, codigo_barras);


--
-- Name: posiciones posiciones_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".posiciones
    ADD CONSTRAINT posiciones_pkey PRIMARY KEY (id);


--
-- Name: recargos_ventas recargos_ventas_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".recargos_ventas
    ADD CONSTRAINT recargos_ventas_pkey PRIMARY KEY (id);


--
-- Name: recuperacion_clave recuperacion_clave_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".recuperacion_clave
    ADD CONSTRAINT recuperacion_clave_pkey PRIMARY KEY (id);


--
-- Name: roles roles_nombre_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".roles
    ADD CONSTRAINT roles_nombre_key UNIQUE (nombre);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: rutas rutas_codigo_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".rutas
    ADD CONSTRAINT rutas_codigo_key UNIQUE (codigo);


--
-- Name: rutas rutas_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".rutas
    ADD CONSTRAINT rutas_pkey PRIMARY KEY (id);


--
-- Name: tarifas tarifas_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".tarifas
    ADD CONSTRAINT tarifas_pkey PRIMARY KEY (id);


--
-- Name: tarifas tarifas_zona_id_tramo_id_vigente_desde_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".tarifas
    ADD CONSTRAINT tarifas_zona_id_tramo_id_vigente_desde_key UNIQUE (zona_id, tramo_id, vigente_desde);


--
-- Name: tipos_recargo tipos_recargo_codigo_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".tipos_recargo
    ADD CONSTRAINT tipos_recargo_codigo_key UNIQUE (codigo);


--
-- Name: tipos_recargo tipos_recargo_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".tipos_recargo
    ADD CONSTRAINT tipos_recargo_pkey PRIMARY KEY (id);


--
-- Name: tramos tramos_codigo_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".tramos
    ADD CONSTRAINT tramos_codigo_key UNIQUE (codigo);


--
-- Name: tramos tramos_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".tramos
    ADD CONSTRAINT tramos_pkey PRIMARY KEY (id);


--
-- Name: tramos tramos_prioridad_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".tramos
    ADD CONSTRAINT tramos_prioridad_key UNIQUE (prioridad);


--
-- Name: ubicaciones_ruta ubicaciones_ruta_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ubicaciones_ruta
    ADD CONSTRAINT ubicaciones_ruta_pkey PRIMARY KEY (id);


--
-- Name: usuarios usuarios_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".usuarios
    ADD CONSTRAINT usuarios_pkey PRIMARY KEY (id);


--
-- Name: usuarios_roles usuarios_roles_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".usuarios_roles
    ADD CONSTRAINT usuarios_roles_pkey PRIMARY KEY (usuario_id, rol_id);


--
-- Name: vehiculos vehiculos_patente_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".vehiculos
    ADD CONSTRAINT vehiculos_patente_key UNIQUE (patente);


--
-- Name: vehiculos vehiculos_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".vehiculos
    ADD CONSTRAINT vehiculos_pkey PRIMARY KEY (id);


--
-- Name: ventas ventas_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ventas
    ADD CONSTRAINT ventas_pkey PRIMARY KEY (id);


--
-- Name: entregas_bultos vn_entrega_bulto_unico; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".entregas_bultos
    ADD CONSTRAINT vn_entrega_bulto_unico UNIQUE (posicion_id);


--
-- Name: ordenes vn_orden_cerrada_con_vehiculo; Type: CHECK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".ordenes
    ADD CONSTRAINT vn_orden_cerrada_con_vehiculo CHECK ((((estado)::text <> ALL ((ARRAY['carga_confirmada'::character varying, 'carga_parcial'::character varying])::text[])) OR (vehiculo_carga_id IS NOT NULL))) NOT VALID;


--
-- Name: ordenes vn_orden_despachada_con_vehiculo; Type: CHECK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".ordenes
    ADD CONSTRAINT vn_orden_despachada_con_vehiculo CHECK ((((estado)::text <> ALL ((ARRAY['carga_confirmada'::character varying, 'carga_parcial'::character varying, 'en_ruta'::character varying, 'cerrada'::character varying])::text[])) OR (vehiculo_carga_id IS NOT NULL))) NOT VALID;


--
-- Name: posiciones vn_posicion_danada_foto; Type: CHECK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE "VialNex".posiciones
    ADD CONSTRAINT vn_posicion_danada_foto CHECK ((((estado)::text <> 'danada'::text) OR (NULLIF(btrim(foto_url), ''::text) IS NOT NULL))) NOT VALID;


--
-- Name: zonas zonas_nombre_key; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".zonas
    ADD CONSTRAINT zonas_nombre_key UNIQUE (nombre);


--
-- Name: zonas zonas_pkey; Type: CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".zonas
    ADD CONSTRAINT zonas_pkey PRIMARY KEY (id);


--
-- Name: ix_entregas_bultos_entrega; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE INDEX ix_entregas_bultos_entrega ON "VialNex".entregas_bultos USING btree (entrega_id);


--
-- Name: ix_ordenes_asignada; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE INDEX ix_ordenes_asignada ON "VialNex".ordenes USING btree (asignada_a, estado) WHERE (asignada_a IS NOT NULL);


--
-- Name: ix_ordenes_vehiculo_carga; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE INDEX ix_ordenes_vehiculo_carga ON "VialNex".ordenes USING btree (vehiculo_carga_id) WHERE (vehiculo_carga_id IS NOT NULL);


--
-- Name: ix_recuperacion_usuario; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE INDEX ix_recuperacion_usuario ON "VialNex".recuperacion_clave USING btree (usuario_id, usado_en, expira_en);


--
-- Name: uq_roles_nombre; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE UNIQUE INDEX uq_roles_nombre ON "VialNex".roles USING btree (lower((nombre)::text));


--
-- Name: usuarios_email_unico; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE UNIQUE INDEX usuarios_email_unico ON "VialNex".usuarios USING btree (lower((email)::text));


--
-- Name: ux_usuarios_rut; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE UNIQUE INDEX ux_usuarios_rut ON "VialNex".usuarios USING btree (rut) WHERE (rut IS NOT NULL);


--
-- Name: vn_cargos_venta; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE INDEX vn_cargos_venta ON "VialNex".cargos USING btree (venta_id);


--
-- Name: vn_detalle_venta; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE INDEX vn_detalle_venta ON "VialNex".detalle_ventas USING btree (venta_id);


--
-- Name: vn_eventos_posicion_fecha; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE INDEX vn_eventos_posicion_fecha ON "VialNex".eventos_carga USING btree (posicion_id, ocurrido_en);


--
-- Name: vn_guias_venta; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE INDEX vn_guias_venta ON "VialNex".guias USING btree (venta_id);


--
-- Name: vn_historial_estado_fecha; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE INDEX vn_historial_estado_fecha ON "VialNex".orden_estados USING btree (estado, cambiado_en DESC, id DESC);


--
-- Name: vn_historial_orden_fecha; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE INDEX vn_historial_orden_fecha ON "VialNex".orden_estados USING btree (orden_id, cambiado_en DESC, id DESC);


--
-- Name: vn_ordenes_estado; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE INDEX vn_ordenes_estado ON "VialNex".ordenes USING btree (estado);


--
-- Name: vn_pago_referencia_unica; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE UNIQUE INDEX vn_pago_referencia_unica ON "VialNex".pagos USING btree (cargo_id, lower(btrim((referencia)::text))) WHERE (NULLIF(btrim((referencia)::text), ''::text) IS NOT NULL);


--
-- Name: vn_pagos_cargo; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE INDEX vn_pagos_cargo ON "VialNex".pagos USING btree (cargo_id);


--
-- Name: vn_posiciones_orden; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE INDEX vn_posiciones_orden ON "VialNex".posiciones USING btree (orden_id);


--
-- Name: vn_ubicaciones_ruta_fecha; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE INDEX vn_ubicaciones_ruta_fecha ON "VialNex".ubicaciones_ruta USING btree (ruta_id, capturada_en DESC);


--
-- Name: vn_una_reposicion; Type: INDEX; Schema: VialNex; Owner: -
--

CREATE UNIQUE INDEX vn_una_reposicion ON "VialNex".ordenes USING btree (orden_origen_id) WHERE (orden_origen_id IS NOT NULL);


--
-- Name: usuarios_roles tg_un_rol_movil; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE CONSTRAINT TRIGGER tg_un_rol_movil AFTER INSERT OR UPDATE ON "VialNex".usuarios_roles DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "VialNex".un_solo_rol_movil();


--
-- Name: ordenes vn_auditar_estado; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE TRIGGER vn_auditar_estado AFTER INSERT OR UPDATE OF estado ON "VialNex".ordenes FOR EACH ROW EXECUTE FUNCTION "VialNex".auditar_estado_orden();


--
-- Name: cargos vn_cargo_aprobado_protegido; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE TRIGGER vn_cargo_aprobado_protegido BEFORE DELETE OR UPDATE ON "VialNex".cargos FOR EACH ROW EXECUTE FUNCTION "VialNex".proteger_cargo_aprobado();


--
-- Name: eventos_carga vn_copiar_evidencia; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE TRIGGER vn_copiar_evidencia AFTER INSERT ON "VialNex".eventos_carga FOR EACH ROW EXECUTE FUNCTION "VialNex".copiar_evidencia_principal();


--
-- Name: entregas_bultos vn_entrega_bulto_inmutable; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE TRIGGER vn_entrega_bulto_inmutable BEFORE DELETE OR UPDATE ON "VialNex".entregas_bultos FOR EACH ROW EXECUTE FUNCTION "VialNex".proteger_entrega_bulto();


--
-- Name: entregas vn_entrega_inmutable; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE TRIGGER vn_entrega_inmutable BEFORE DELETE OR UPDATE ON "VialNex".entregas FOR EACH ROW EXECUTE FUNCTION "VialNex".proteger_intento_entrega();


--
-- Name: eventos_carga vn_evento_inmutable; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE TRIGGER vn_evento_inmutable BEFORE DELETE OR UPDATE ON "VialNex".eventos_carga FOR EACH ROW EXECUTE FUNCTION "VialNex".bloquear_edicion_evento();


--
-- Name: evidencias vn_evidencia_inmutable; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE TRIGGER vn_evidencia_inmutable BEFORE DELETE OR UPDATE ON "VialNex".evidencias FOR EACH ROW EXECUTE FUNCTION "VialNex".proteger_historial_bodega();


--
-- Name: orden_estados vn_historial_inmutable; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE TRIGGER vn_historial_inmutable BEFORE DELETE OR UPDATE ON "VialNex".orden_estados FOR EACH ROW EXECUTE FUNCTION "VialNex".proteger_historial_bodega();


--
-- Name: pagos vn_pago_inmutable; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE TRIGGER vn_pago_inmutable BEFORE DELETE OR UPDATE ON "VialNex".pagos FOR EACH ROW EXECUTE FUNCTION "VialNex".proteger_pago();


--
-- Name: posiciones vn_posicion_protegida; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE TRIGGER vn_posicion_protegida BEFORE DELETE OR UPDATE ON "VialNex".posiciones FOR EACH ROW EXECUTE FUNCTION "VialNex".proteger_posicion_procesada();


--
-- Name: usuarios vn_usuario_modificado; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE TRIGGER vn_usuario_modificado BEFORE UPDATE ON "VialNex".usuarios FOR EACH ROW EXECUTE FUNCTION "VialNex".marcar_usuario_modificado();


--
-- Name: ordenes vn_validar_orden_bodega; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE CONSTRAINT TRIGGER vn_validar_orden_bodega AFTER INSERT OR UPDATE ON "VialNex".ordenes DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "VialNex".validar_integridad_bodega();


--
-- Name: pagos vn_validar_pago; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE TRIGGER vn_validar_pago BEFORE INSERT ON "VialNex".pagos FOR EACH ROW EXECUTE FUNCTION "VialNex".validar_pago();


--
-- Name: posiciones vn_validar_posicion_bodega; Type: TRIGGER; Schema: VialNex; Owner: -
--

CREATE CONSTRAINT TRIGGER vn_validar_posicion_bodega AFTER INSERT OR UPDATE ON "VialNex".posiciones DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "VialNex".validar_integridad_bodega();


--
-- Name: cambios_ruta cambios_ruta_cambiado_por_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".cambios_ruta
    ADD CONSTRAINT cambios_ruta_cambiado_por_fkey FOREIGN KEY (cambiado_por) REFERENCES "VialNex".usuarios(id);


--
-- Name: cambios_ruta cambios_ruta_orden_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".cambios_ruta
    ADD CONSTRAINT cambios_ruta_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES "VialNex".ordenes(id);


--
-- Name: cambios_ruta cambios_ruta_ruta_anterior_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".cambios_ruta
    ADD CONSTRAINT cambios_ruta_ruta_anterior_id_fkey FOREIGN KEY (ruta_anterior_id) REFERENCES "VialNex".rutas(id);


--
-- Name: cambios_ruta cambios_ruta_ruta_nueva_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".cambios_ruta
    ADD CONSTRAINT cambios_ruta_ruta_nueva_id_fkey FOREIGN KEY (ruta_nueva_id) REFERENCES "VialNex".rutas(id);


--
-- Name: cargos cargos_aprobado_por_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".cargos
    ADD CONSTRAINT cargos_aprobado_por_fkey FOREIGN KEY (aprobado_por) REFERENCES "VialNex".usuarios(id);


--
-- Name: cargos cargos_creado_por_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".cargos
    ADD CONSTRAINT cargos_creado_por_fkey FOREIGN KEY (creado_por) REFERENCES "VialNex".usuarios(id);


--
-- Name: cargos cargos_entrega_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".cargos
    ADD CONSTRAINT cargos_entrega_id_fkey FOREIGN KEY (entrega_id) REFERENCES "VialNex".entregas(id);


--
-- Name: cargos cargos_venta_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".cargos
    ADD CONSTRAINT cargos_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES "VialNex".ventas(id);


--
-- Name: comunas comunas_zona_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".comunas
    ADD CONSTRAINT comunas_zona_id_fkey FOREIGN KEY (zona_id) REFERENCES "VialNex".zonas(id);


--
-- Name: costos_vehiculo costos_vehiculo_vehiculo_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".costos_vehiculo
    ADD CONSTRAINT costos_vehiculo_vehiculo_id_fkey FOREIGN KEY (vehiculo_id) REFERENCES "VialNex".vehiculos(id);


--
-- Name: detalle_ventas detalle_ventas_tarifa_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".detalle_ventas
    ADD CONSTRAINT detalle_ventas_tarifa_id_fkey FOREIGN KEY (tarifa_id) REFERENCES "VialNex".tarifas(id);


--
-- Name: detalle_ventas detalle_ventas_venta_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".detalle_ventas
    ADD CONSTRAINT detalle_ventas_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES "VialNex".ventas(id);


--
-- Name: documentos documentos_guia_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".documentos
    ADD CONSTRAINT documentos_guia_id_fkey FOREIGN KEY (guia_id) REFERENCES "VialNex".guias(id);


--
-- Name: documentos documentos_personal_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".documentos
    ADD CONSTRAINT documentos_personal_id_fkey FOREIGN KEY (personal_id) REFERENCES "VialNex".personal(id);


--
-- Name: documentos documentos_vehiculo_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".documentos
    ADD CONSTRAINT documentos_vehiculo_id_fkey FOREIGN KEY (vehiculo_id) REFERENCES "VialNex".vehiculos(id);


--
-- Name: entregas_bultos entregas_bultos_entrega_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".entregas_bultos
    ADD CONSTRAINT entregas_bultos_entrega_id_fkey FOREIGN KEY (entrega_id) REFERENCES "VialNex".entregas(id);


--
-- Name: entregas_bultos entregas_bultos_motivo_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".entregas_bultos
    ADD CONSTRAINT entregas_bultos_motivo_id_fkey FOREIGN KEY (motivo_id) REFERENCES "VialNex".motivos_entrega_fallida(id);


--
-- Name: entregas_bultos entregas_bultos_posicion_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".entregas_bultos
    ADD CONSTRAINT entregas_bultos_posicion_id_fkey FOREIGN KEY (posicion_id) REFERENCES "VialNex".posiciones(id);


--
-- Name: entregas entregas_motivo_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".entregas
    ADD CONSTRAINT entregas_motivo_id_fkey FOREIGN KEY (motivo_id) REFERENCES "VialNex".motivos_entrega_fallida(id);


--
-- Name: entregas entregas_parada_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".entregas
    ADD CONSTRAINT entregas_parada_id_fkey FOREIGN KEY (parada_id) REFERENCES "VialNex".paradas_ruta(id);


--
-- Name: entregas entregas_registrada_por_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".entregas
    ADD CONSTRAINT entregas_registrada_por_fkey FOREIGN KEY (registrada_por) REFERENCES "VialNex".usuarios(id);


--
-- Name: eventos_carga eventos_carga_posicion_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".eventos_carga
    ADD CONSTRAINT eventos_carga_posicion_id_fkey FOREIGN KEY (posicion_id) REFERENCES "VialNex".posiciones(id);


--
-- Name: eventos_carga eventos_carga_usuario_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".eventos_carga
    ADD CONSTRAINT eventos_carga_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES "VialNex".usuarios(id);


--
-- Name: evidencias evidencias_evento_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".evidencias
    ADD CONSTRAINT evidencias_evento_id_fkey FOREIGN KEY (evento_id) REFERENCES "VialNex".eventos_carga(id);


--
-- Name: evidencias evidencias_subida_por_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".evidencias
    ADD CONSTRAINT evidencias_subida_por_fkey FOREIGN KEY (subida_por) REFERENCES "VialNex".usuarios(id);


--
-- Name: facturas_cargos facturas_cargos_cargo_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".facturas_cargos
    ADD CONSTRAINT facturas_cargos_cargo_id_fkey FOREIGN KEY (cargo_id) REFERENCES "VialNex".cargos(id);


--
-- Name: facturas_cargos facturas_cargos_factura_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".facturas_cargos
    ADD CONSTRAINT facturas_cargos_factura_id_fkey FOREIGN KEY (factura_id) REFERENCES "VialNex".facturas(id);


--
-- Name: facturas facturas_cliente_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".facturas
    ADD CONSTRAINT facturas_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES "VialNex".clientes(id);


--
-- Name: guias guias_orden_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".guias
    ADD CONSTRAINT guias_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES "VialNex".ordenes(id);


--
-- Name: guias guias_venta_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".guias
    ADD CONSTRAINT guias_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES "VialNex".ventas(id);


--
-- Name: hitos_ruta hitos_ruta_registrado_por_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".hitos_ruta
    ADD CONSTRAINT hitos_ruta_registrado_por_fkey FOREIGN KEY (registrado_por) REFERENCES "VialNex".usuarios(id);


--
-- Name: hitos_ruta hitos_ruta_ruta_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".hitos_ruta
    ADD CONSTRAINT hitos_ruta_ruta_id_fkey FOREIGN KEY (ruta_id) REFERENCES "VialNex".rutas(id);


--
-- Name: mantenimientos mantenimientos_vehiculo_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".mantenimientos
    ADD CONSTRAINT mantenimientos_vehiculo_id_fkey FOREIGN KEY (vehiculo_id) REFERENCES "VialNex".vehiculos(id);


--
-- Name: orden_estados orden_estados_cambiado_por_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".orden_estados
    ADD CONSTRAINT orden_estados_cambiado_por_fkey FOREIGN KEY (cambiado_por) REFERENCES "VialNex".usuarios(id);


--
-- Name: orden_estados orden_estados_orden_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".orden_estados
    ADD CONSTRAINT orden_estados_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES "VialNex".ordenes(id);


--
-- Name: ordenes ordenes_asignada_a_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ordenes
    ADD CONSTRAINT ordenes_asignada_a_fkey FOREIGN KEY (asignada_a) REFERENCES "VialNex".usuarios(id);


--
-- Name: ordenes ordenes_asignada_por_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ordenes
    ADD CONSTRAINT ordenes_asignada_por_fkey FOREIGN KEY (asignada_por) REFERENCES "VialNex".usuarios(id);


--
-- Name: ordenes ordenes_carga_confirmada_por_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ordenes
    ADD CONSTRAINT ordenes_carga_confirmada_por_fkey FOREIGN KEY (carga_confirmada_por) REFERENCES "VialNex".usuarios(id);


--
-- Name: ordenes ordenes_creada_por_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ordenes
    ADD CONSTRAINT ordenes_creada_por_fkey FOREIGN KEY (creada_por) REFERENCES "VialNex".usuarios(id);


--
-- Name: ordenes ordenes_orden_origen_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ordenes
    ADD CONSTRAINT ordenes_orden_origen_id_fkey FOREIGN KEY (orden_origen_id) REFERENCES "VialNex".ordenes(id);


--
-- Name: ordenes ordenes_ruta_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ordenes
    ADD CONSTRAINT ordenes_ruta_id_fkey FOREIGN KEY (ruta_id) REFERENCES "VialNex".rutas(id);


--
-- Name: ordenes ordenes_vehiculo_carga_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ordenes
    ADD CONSTRAINT ordenes_vehiculo_carga_id_fkey FOREIGN KEY (vehiculo_carga_id) REFERENCES "VialNex".vehiculos(id);


--
-- Name: pagos pagos_cargo_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".pagos
    ADD CONSTRAINT pagos_cargo_id_fkey FOREIGN KEY (cargo_id) REFERENCES "VialNex".cargos(id);


--
-- Name: pagos pagos_registrado_por_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".pagos
    ADD CONSTRAINT pagos_registrado_por_fkey FOREIGN KEY (registrado_por) REFERENCES "VialNex".usuarios(id);


--
-- Name: paradas_ruta paradas_ruta_guia_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".paradas_ruta
    ADD CONSTRAINT paradas_ruta_guia_id_fkey FOREIGN KEY (guia_id) REFERENCES "VialNex".guias(id);


--
-- Name: paradas_ruta paradas_ruta_ruta_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".paradas_ruta
    ADD CONSTRAINT paradas_ruta_ruta_id_fkey FOREIGN KEY (ruta_id) REFERENCES "VialNex".rutas(id);


--
-- Name: personal personal_usuario_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".personal
    ADD CONSTRAINT personal_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES "VialNex".usuarios(id);


--
-- Name: posiciones posiciones_detalle_venta_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".posiciones
    ADD CONSTRAINT posiciones_detalle_venta_id_fkey FOREIGN KEY (detalle_venta_id) REFERENCES "VialNex".detalle_ventas(id);


--
-- Name: posiciones posiciones_guia_id_orden_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".posiciones
    ADD CONSTRAINT posiciones_guia_id_orden_id_fkey FOREIGN KEY (guia_id, orden_id) REFERENCES "VialNex".guias(id, orden_id);


--
-- Name: posiciones posiciones_marcada_por_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".posiciones
    ADD CONSTRAINT posiciones_marcada_por_fkey FOREIGN KEY (marcada_por) REFERENCES "VialNex".usuarios(id);


--
-- Name: posiciones posiciones_orden_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".posiciones
    ADD CONSTRAINT posiciones_orden_id_fkey FOREIGN KEY (orden_id) REFERENCES "VialNex".ordenes(id);


--
-- Name: recargos_ventas recargos_ventas_tipo_recargo_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".recargos_ventas
    ADD CONSTRAINT recargos_ventas_tipo_recargo_id_fkey FOREIGN KEY (tipo_recargo_id) REFERENCES "VialNex".tipos_recargo(id);


--
-- Name: recargos_ventas recargos_ventas_venta_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".recargos_ventas
    ADD CONSTRAINT recargos_ventas_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES "VialNex".ventas(id);


--
-- Name: recuperacion_clave recuperacion_clave_usuario_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".recuperacion_clave
    ADD CONSTRAINT recuperacion_clave_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES "VialNex".usuarios(id) ON DELETE CASCADE;


--
-- Name: rutas rutas_conductor_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".rutas
    ADD CONSTRAINT rutas_conductor_id_fkey FOREIGN KEY (conductor_id) REFERENCES "VialNex".personal(id);


--
-- Name: rutas rutas_vehiculo_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".rutas
    ADD CONSTRAINT rutas_vehiculo_id_fkey FOREIGN KEY (vehiculo_id) REFERENCES "VialNex".vehiculos(id);


--
-- Name: tarifas tarifas_tramo_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".tarifas
    ADD CONSTRAINT tarifas_tramo_id_fkey FOREIGN KEY (tramo_id) REFERENCES "VialNex".tramos(id);


--
-- Name: tarifas tarifas_zona_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".tarifas
    ADD CONSTRAINT tarifas_zona_id_fkey FOREIGN KEY (zona_id) REFERENCES "VialNex".zonas(id);


--
-- Name: ubicaciones_ruta ubicaciones_ruta_registrado_por_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ubicaciones_ruta
    ADD CONSTRAINT ubicaciones_ruta_registrado_por_fkey FOREIGN KEY (registrado_por) REFERENCES "VialNex".usuarios(id);


--
-- Name: ubicaciones_ruta ubicaciones_ruta_ruta_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ubicaciones_ruta
    ADD CONSTRAINT ubicaciones_ruta_ruta_id_fkey FOREIGN KEY (ruta_id) REFERENCES "VialNex".rutas(id);


--
-- Name: usuarios usuarios_modificado_por_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".usuarios
    ADD CONSTRAINT usuarios_modificado_por_fkey FOREIGN KEY (modificado_por) REFERENCES "VialNex".usuarios(id);


--
-- Name: usuarios_roles usuarios_roles_rol_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".usuarios_roles
    ADD CONSTRAINT usuarios_roles_rol_id_fkey FOREIGN KEY (rol_id) REFERENCES "VialNex".roles(id);


--
-- Name: usuarios_roles usuarios_roles_usuario_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".usuarios_roles
    ADD CONSTRAINT usuarios_roles_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES "VialNex".usuarios(id);


--
-- Name: ventas ventas_cliente_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ventas
    ADD CONSTRAINT ventas_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES "VialNex".clientes(id);


--
-- Name: ventas ventas_vendedor_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ventas
    ADD CONSTRAINT ventas_vendedor_id_fkey FOREIGN KEY (vendedor_id) REFERENCES "VialNex".usuarios(id);


--
-- Name: ventas ventas_zona_id_fkey; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ventas
    ADD CONSTRAINT ventas_zona_id_fkey FOREIGN KEY (zona_id) REFERENCES "VialNex".zonas(id);


--
-- Name: ventas vn_venta_comuna_zona; Type: FK CONSTRAINT; Schema: VialNex; Owner: -
--

ALTER TABLE ONLY "VialNex".ventas
    ADD CONSTRAINT vn_venta_comuna_zona FOREIGN KEY (comuna_id, zona_id) REFERENCES "VialNex".comunas(id, zona_id);


--
-- PostgreSQL database dump complete
--

\unrestrict 5esKaldsUTglEPlMhDr91gBKEGIqCz5P9qPvtN0h48WObCkHenRdvW2agizUcZm

