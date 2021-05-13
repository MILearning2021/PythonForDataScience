	
----- получаю список таблиц и представлений БД bookings

select mv.relname "Имя",
	   case when position(mv.relkind in 'rvm') =1 then 'Таблица'
	   		when position(mv.relkind in 'rvm') =2 then 'Представление'
	   		when position(mv.relkind in 'rvm') =3 then 'Мат.представление'
	   end "Тип",
	   pg_size_pretty(pg_relation_size(mv.oid)) AS "Текущий размер",
	   dsc.description "Описание"
from pg_class mv
  join pg_namespace ns 
  	on mv.relnamespace = ns.oid
  join pg_description dsc 
  	on mv.oid = dsc.objoid 
where ns.nspname = 'bookings' and position(mv.relkind in 'rvm') >0 and dsc.objsubid = 0
order by "Имя";

----- запросы к базе данных согласно вопросам из Приложения 2

set search_path to bookings;

----- №1 В каких городах больше одного аэропорта?

--Группировка по полю “city” с агрегатной функцией count и сравнение с "1"
select "Город", "Количество аэропортов"
from (
	select city "Город", count(airport_code) "Количество аэропортов"
	from airports a 
	group by city
	) as airports_count
where "Количество аэропортов" > 1;

----- №2 В каких аэропортах есть рейсы, выполняемые самолетом с максимальной дальностью перелета?

--нахожу подзапросом максимальный радиус полета самолетов, от таблицы airports через связи к flights и aircrafts собираю промежуточный набор,
--применяю условие на основе подзапроса и сортирую
select distinct a.airport_name "Название аэропорта", a2."range" 
from airports a 
	inner join flights f
		on a.airport_code = f.departure_airport 
	inner join aircrafts a2 
		on f.aircraft_code = a2.aircraft_code 
where a2."range" = (select max(range) from aircrafts)
order by "Название аэропорта";

----- №3 Вывести 10 рейсов с максимальным временем задержки вылета

--из таблицы fligths выираю рейсы, которые улетели, получаю разницу со временем в расписании, применяю сортировку по убыванию этой разницыс целью 
--получить однозначный набор данных и отбираю верхние строк
select f.flight_id "FlightID", 
	   f.flight_no "Flight №", 
	   f.actual_departure - f.scheduled_departure "Delay time"
from flights f
where f.actual_departure is not null
order by "Delay time" desc
limit 10;

----- №4 Были ли брони, по которым не были получены посадочные талоны?

--номер брони есть в таблице tickets, а факт получения посадочного таллона фиксируется в boarding_passes, делаю соединение этих таблиц 
--по общему признаку ticket_no, выбираю никальные бронирования и считаю их количество, далее проверяю условие равенства этого количества "0"
with no_bp as (
	select count(distinct book_ref) as col
	from tickets t
		left join boarding_passes bp 
			on t.ticket_no = bp.ticket_no
	where bp.ticket_no is null
	)
select case 
			when col = 0 then 'Бронирований, по которым не было получено посадочных талонов, НЕТ!'
			when col > 0 then 'Бронирований, по которым не было получено посадочных талонов, ' || col || ' штук.'
	   end
from no_bp;

----- №5 Найдите свободные места для каждого рейса, их % отношение к общему количеству мест в самолете.
----- Добавьте столбец с накопительным итогом - суммарное накопление количества вывезенных пассажиров из каждого аэропорта на каждый день. 
----- Т.е. в этом столбце должна отражаться накопительная сумма - сколько человек уже вылетело из данного аэропорта на этом или более ранних 
----- рейсах за день.

--- свобоные места для каждого рейса и их % отношения к общему количеству мест в самолете
select gr_qry."FlightID",
	   gr_qry."Количество свободных мест", 
	   gr_seats."Всего мест",
	   round(gr_qry."Количество свободных мест"::numeric/gr_seats."Всего мест",4) * 100 "Свободно мест, %"
from (select "FlightID", count("Seat") "Количество свободных мест" ---сумма свободных мест на рейсе
	  from (
			select f.flight_id "FlightID", s.seat_no "Seat" ---все места на всех рейсах
			from flights f 
				join aircrafts a
					on f.aircraft_code = a.aircraft_code 
				join seats s
					on a.aircraft_code = s.aircraft_code
			except											---из всех возможных мест убираю занятые места, получаю набор свободных мест
			select f.flight_id "FlightID", bp.seat_no "Seat" ---занятые места на всех рейсах
			from flights f
				join boarding_passes bp
					on f.flight_id = bp.flight_id
	   ) as qry
	   group by "FlightID"
	   order by "FlightID"
) as gr_qry
	join (select f.flight_id "FlightID", count(s.seat_no) "Всего мест" --- сумма всех мест на рейсе для получения требуемого отношения %
		  from flights f 
		  	join aircrafts a
				on f.aircraft_code = a.aircraft_code 
			join seats s
				on a.aircraft_code = s.aircraft_code
		  group by "FlightID"
	) as gr_seats
		on gr_qry."FlightID" = gr_seats."FlightID";

--- Добавьте столбец с накопительным итогом - суммарное накопление количества вывезенных пассажиров из каждого аэропорта на каждый день	
select gr_qry."Аэропорт вылета",
	   gr_qry."Дата вылета"::date,
	   gr_qry."Рейс",
	   gr_qry."Количество свободных мест", 
	   gr_seats."Всего мест",
	   round(gr_qry."Количество свободных мест"::numeric/gr_seats."Всего мест",4) * 100 "Свободно мест, %",
	   --окно по уникальному признаку и суммирование с накоплением
	   sum(gr_seats."Всего мест"- gr_qry."Количество свободных мест") over (partition by gr_qry."Аэропорт вылета", gr_qry."Дата вылета"::date order by gr_qry."Рейс") as part
from (select "FlightID", "Дата вылета", "Аэропорт вылета", "Рейс", count("Seat") "Количество свободных мест" ---сумма свободных мест на рейсе
	  from (
			select f.flight_id "FlightID", f.actual_departure "Дата вылета", a2.airport_name "Аэропорт вылета", s.seat_no "Seat", ---все места на всех рейсах
				   f.flight_no "Рейс"
			from flights f 
				join aircrafts a
					on f.aircraft_code = a.aircraft_code 
				join seats s
					on a.aircraft_code = s.aircraft_code
				join airports a2 
					on f.departure_airport = a2.airport_code 
			except											--получаю набор свободных мест разницей двух наборов
			select f.flight_id "FlightID", f.actual_departure "Дата вылета", a2.airport_name "Аэропорт вылета", bp.seat_no "Seat", ---занятые места на всех рейсах
			f.flight_no "Рейс"
			from flights f
				join boarding_passes bp
					on f.flight_id = bp.flight_id
				join airports a2 
					on f.departure_airport = a2.airport_code
	   ) as qry
	   where "Дата вылета" is not null
	   group by "FlightID", "Дата вылета", "Аэропорт вылета", "Рейс"
	   order by "Аэропорт вылета", "Дата вылета"
) as gr_qry
	join (select f.flight_id "FlightID", count(s.seat_no) "Всего мест" --- сумма всех мест на рейсе
		  from flights f 
		  	join aircrafts a
				on f.aircraft_code = a.aircraft_code 
			join seats s
				on a.aircraft_code = s.aircraft_code
		  group by "FlightID"
	) as gr_seats
		on gr_qry."FlightID" = gr_seats."FlightID";

----- №6 Найдите процентное соотношение перелетов по типам самолетов от общего количества

--формирую набор перелеты/самолеты, группирую по модели самолета, получаю количество перелетов по моделям самолетов,
--подзапросом получаю общее количество перелетов, считаю % каждой модели самолета в общем количестве перелетов (испольльзую округление,
--перевожу в проценты)
select a.model "Тип самолета", 
	   count(f.flight_id) "Количество перелетов", 
	   round(count(f.flight_id)::numeric/(select count(*) from flights),4) * 100 "От общего количества перелетов, %"
from aircrafts a
	join flights f
		on a.aircraft_code = f.aircraft_code
group by a.model
		
----- №7 Были ли города, в которые можно  добраться бизнес - классом дешевле, чем эконом-классом в рамках перелета?

with cte_cf as (						--формирую набор данными о перелетах, их стоимости и аэропортах
	select a.city "Город",
		   f.flight_id "Перелет",
	   	   tf.fare_conditions "Класс",
	   	   min(tf.amount) "Сумма"
	from ticket_flights tf 
		join flights f
			on tf.flight_id = f.flight_id
		join airports a	
			on f.arrival_airport = a.airport_code 
	group by f.flight_id, tf.fare_conditions, a.city
), 
cte_bkl as (							--формирую набор перелетов бизнесс-классом, использую данные временной таблицу cte_cf
	select cte_cf."Перелет",
		   cte_cf."Город",
		   cte_cf."Сумма" "БКл"
	from cte_cf
	where cte_cf."Класс" = 'Business'
	order by cte_cf."Перелет"
),
cte_ekl as (						--формирую набор перелетов эконом-классом, использую данные временной таблицу cte_cf
	select cte_cf."Перелет",
		   cte_cf."Сумма" "ЭКл"
	from cte_cf
	where cte_cf."Класс" = 'Economy'
	order by cte_cf."Перелет"
)
select cte_bkl."Город", cte_bkl."Перелет", cte_bkl."БКл", cte_ekl."ЭКл" --формирую набор перелетов, где БКл дешевле ЭКл, использую данные временных таблиц
from cte_bkl
	join cte_ekl
		on cte_bkl."Перелет"=cte_ekl."Перелет"
where cte_bkl."БКл" < cte_ekl."ЭКл"
order by cte_bkl."Город", cte_bkl."Перелет", cte_bkl."БКл", cte_ekl."ЭКл"

----- №8 Между какими городами нет прямых рейсов?

refresh materialized view routes;	--для формирования набора данных буду исполльзовать имеющееся мат.представление routes
drop view if exists all_possible_routes;
create view all_possible_routes (dep_city,arr_city) as ( --формирую список всех возможных пар городов cross join таблицы самой на себя
	select a1.city, a2.city 
	from airports a1
		cross join airports a2 
);
drop view if exists all_existing_routes;
create view all_existing_routes (dep_city,arr_city) as ( --формирую список всех существующих прямых рейсов, они же "существующие пары городов"
	select r.departure_city, r.arrival_city 
	from routes r
);
select dep_city "Пункт вылета", arr_city "Пункт назначения" --вывожу список пар городов по условию в задаче
from (
		select * from all_possible_routes
		except						--все возможные пары городов - существующие пары городов
		select * from all_existing_routes
) as not_existing_routes
where dep_city <> arr_city   --убираю пары вида "Москва-Москва"
order by dep_city, arr_city;

----- №9 Вычислите расстояние между аэропортами, связанными прямыми рейсами, 
----- сравните с допустимой максимальной дальностью перелетов  в самолетах, обслуживающих эти рейсы

select L.*, 			--обогащение сводной таблицы данными о макс радиусе полета самолетов по типам, используемым на рейсах, и сравнение с расстоянияи междуаэропортами, соединенными этими рейсами
	   a2."range" "Дальность полета самолета",
	   case when L."L" > a2."range" then 'Беда!'
	   		when L."L" = a2."range" then 'Внимание!'
	   		else 'Долетим!'
	   end "Ситуация"
from (
	select dep_ap.flight_no "Номер рейса",     --формирование сводной таблицы с данными для рассчета расстояния и рассчет расстояния между аэропортов
		   dep_ap.aircraft_code "Код самолета",
	   	   dep_ap.departure_airport "Пункт1",
	       dep_ap.latitude "Шир1",
	       dep_ap.longitude "Долг1",
	   	   arr_ap.arrival_airport "Пункт2",
	   	   arr_ap.latitude "Шир2",
	   	   arr_ap.longitude "Долг2",
	   	   round(acos(sind(dep_ap.latitude) * sind(arr_ap.latitude) + cosd(dep_ap.latitude) * cosd(arr_ap.latitude) * cosd(dep_ap.longitude - arr_ap.longitude))::numeric,2) * 6371 "L"
	from (
			select r.flight_no, r.aircraft_code, r.departure_airport, a.latitude, a.longitude --выборка из мат представления существующих прямых рейсов и координат аэропортов вылета
			from routes r 
				join airports a 
					on r.departure_airport = a.airport_code
		) as dep_ap
	join (	
			select r.flight_no, r.arrival_airport , a.latitude, a.longitude --выборка из мат представления существующих прямых рейсов и координат аэропортов прилета
			from routes r 
				join airports a 
					on r.arrival_airport = a.airport_code
		) as arr_ap
		on dep_ap.flight_no = arr_ap.flight_no
	) as L
	left join aircrafts a2
		on L."Код самолета" = a2.aircraft_code;
