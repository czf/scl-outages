SELECT 
      [SERV_LOC_ID]
      ,STRING_AGG([EVENT_IDX],',') WITHIN GROUP (ORDER by event_idx ASC )
      ,count(SERV_LOC_ID)
      
  FROM [SclOutage].[dbo].[OMS_Device_Outages_2024]
group by SERV_LOC_ID
order by count(1)



select distinct serv_loc_id , cast(format( MAX_POINT_X,'0.################')as varchar(128)) as max_point_x
from OMS_Device_Outages_2024
where SERV_LOC_ID = 1760

1270881.27
1270881.27


--SELECT 
--    MAX_POINT_X, 
--    CAST(MAX_POINT_X AS VARBINARY(8)) AS BinaryValue,
--    FORMAT(MAX_POINT_X, '0.############################') AS HighPrecision
--FROM OMS_Device_Outages_2024
--WHERE SERV_LOC_ID = 1760;


select * from OMS_Device_Outages_2024
where MAX_POINT_X is null or MAX_POINT_Y is null

SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'

select count (*) from oms_device_outages_2024_wgs84_tmp with (nolock)
select count (*) from oms_device_outages_2024 with (nolock)
where MAX_POINT_X_AS_WGS84_LONGITUDE is null



ALTER TABLE select top 2 * From oms_device_outages_2024_wgs84_tmp
ADD CONSTRAINT PK_$SrcTable PRIMARY KEY CLUSTERED (EVENT_IDX, SERV_LOC_ID);
