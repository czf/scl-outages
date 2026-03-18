with d_max_x as(

select distinct serv_loc_id , cast(format( MAX_POINT_X,'0.################')as varchar(128)) as max_point_x
from OMS_Device_Outages_2024)
--, d_max_y as(
--select distinct serv_loc_id, cast(format( MAX_POINT_y,'0.################')as varchar(128)) as max_point_y
--from OMS_Device_Outages_2024
--)
SELECT 
      x.[SERV_LOC_ID]
      ,x.max_point_x
      --,STRING_AGG(x.max_point_x,',') WITHIN GROUP (ORDER by x.max_point_x ASC )
      --,STRING_AGG(y.max_point_y,',') WITHIN GROUP (ORDER by y.max_point_y ASC )
      
      
  FROM 
  --[SclOutage].[dbo].[OMS_Device_Outages_2024] o
  --inner join 
  d_max_x x --on o.SERV_LOC_ID =  x.SERV_LOC_ID
  --inner join d_max_y y on o.SERV_LOC_ID =  y.SERV_LOC_ID
group by x.SERV_LOC_ID , x.max_point_x
having count(max_point_x) >1
order by SERV_LOC_ID;

SELECT 
      x.[SERV_LOC_ID]
      ,cast(format( x.MAX_POINT_X,'0.################')as varchar(128)) as px
      ,count(1)
      --,STRING_AGG(x.max_point_x,',') WITHIN GROUP (ORDER by x.max_point_x ASC )
      --,STRING_AGG(y.max_point_y,',') WITHIN GROUP (ORDER by y.max_point_y ASC )
      
      
  FROM 
  --[SclOutage].[dbo].[OMS_Device_Outages_2024] o
  --inner join 
  OMS_Device_Outages_2024 x --on o.SERV_LOC_ID =  x.SERV_LOC_ID
  --inner join d_max_y y on o.SERV_LOC_ID =  y.SERV_LOC_ID
group by x.SERV_LOC_ID , cast(format( x.MAX_POINT_X,'0.################')as varchar(128))
having count(cast(format( x.MAX_POINT_X,'0.################')as varchar(128)) ) >1
order by SERV_LOC_ID

with distinct_x as (
select distinct serv_loc_id, max_point_y from OMS_Device_Outages_2024 
)
select serv_loc_id,
count(serv_loc_id)
 from distinct_x
 group by SERV_LOC_ID
