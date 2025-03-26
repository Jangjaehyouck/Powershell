Set-ExecutionPolicy bypass -Force

add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13


function Request-RestAPI($URL, $Method, $Body, $version){
    # API URL 적절한 Prism element IP로 변경하실 수 있습니다.
    if($version -eq "v0.8"){
        $version = "v0.8"
    } elseif ($version -eq "v1") {
        $version = "v1"
    } else {
        $version = "v2.0"
    }
    $API_url = "https://" + $global:prismIPaddr + ":9440/PrismGateway/services/rest/$version/$URL"
    # 인코딩할 문자열
    $userpass = "prismuser:prismpass"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($userpass)
    $base64 = [Convert]::ToBase64String($bytes)

    $headers = @{
        "Accept" = "application/json;charset=UTF-8"
        "Authorization" = "Basic $base64"
        "Content-Type" = "application/json;charset=UTF-8"
    }

    if ($Method -eq "GET" -or $Method -eq "DELETE"){
        # GET 요청 실행
        $response = Invoke-WebRequest -Uri $API_url -Method $Method -Headers $headers
        # 응답 데이터 출력 (원시 JSON 데이터)
        $Result = $response.Content | ConvertFrom-Json
    } else {
        $response = Invoke-WebRequest -Uri $API_url -Method $Method -Headers $headers -Body $Body
        $Result = $response
    }

    return $Result
}

Function Query-Mssql {
    Param(
        [parameter(Mandatory=$true)][String]$Query,
        [Int32]$Timeout = "30"
    )

    $Conn = New-Object System.Data.SqlClient.SqlConnection
    $Conn.ConnectionString = "Server=dbip,port;Database=dbname;User ID=user;Password=password"
    $Conn.Open()
    $SqlCmd = New-Object System.Data.SqlClient.SqlCommand
    $SqlCmd.CommandText = $Query
    $SqlCmd.Connection = $Conn
    $SqlCmd.CommandTimeout = $Timeout
    Return $SqlCmd.ExecuteNonQuery()
}

Function Get-MssqlData {

    Param(
        [parameter(Mandatory=$true)][String]$Query,
        [Int32]$Timeout = "30"
    )
    $Conn = New-Object System.Data.SqlClient.SqlConnection
    $Conn.ConnectionString = "Server=dbip,port;Database=dbname;User ID=user;Password=password"
    $Conn.Open()
    $SqlCmd = New-Object System.Data.SqlClient.SqlCommand
    $SqlCmd.CommandText = $Query
    $SqlCmd.Connection = $Conn
    $SqlCmd.CommandTimeout = $Timeout
  
    $SqlDataAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
    $SqlDataAdapter.SelectCommand = $SqlCmd
    $DataSet = New-Object System.Data.DataSet
    $SqlDataAdapter.Fill( $DataSet )
    Return $DataSet.Tables
}

#$test = Get-MssqlData "select * from CMP_DB.[dbo].[tbl_group]"

$dtime = Get-Date -Format "yyyyMMddHH"
$global:prismIPaddr = ""
#Global 변수

$prismIPaddr = New-Object System.Collections.ArrayList
$prismIPaddr.clear()
$prismIPaddr.add("prismURL")
$prismIPaddr.add("prismURL")

foreach($prisminfo in $prismIPaddr){

    $global:prismIPaddr = $prisminfo

    #Get-Cluster Info
    $Clu_info = Request-RestAPI "cluster/" "GET"
    $clunm = $Clu_info.name
    $CPU_Usage = "{0:F2}" -f ($Clu_info.stats.hypervisor_cpu_usage_ppm / 10000)
    $MEM_Usage = "{0:F2}" -f ($Clu_info.stats.hypervisor_memory_usage_ppm / 10000)

    $Query = ""
    $Query = $Query + "INSERT INTO [dbo].[moni_cluster]([ntnx_clu_nm],[clu_cpu_usage],[clu_memory_usage],[create_date])"
    $Query = $Query + "VALUES ('$clunm','$CPU_Usage','$MEM_Usage','$dtime')"

    $NoLog = Query-Mssql $Query

    $array = New-Object System.Collections.ArrayList
    $array.Clear()

    if($clunm -eq "CLU"){
        $array.add("CVM name,CVMUUID")
    } else {
        $array.add("CVM name,CVMUUID")
    }

    foreach($cvm_info in $array){
        $splitcvm = $cvm_info -split(",")
        $cvmname = $splitcvm[0]
        $cvmuuid = $splitcvm[1]

        $URL = "vms/$cvmuuid/stats/?metrics=hypervisor_cpu_usage_ppm%2Cmemory_usage_ppm"
        $CVM_Info = Request-RestAPI "$URL" "GET" "" "v1"
        $cvm_CPU_Usage = ($CVM_Info.statsSpecificResponses | Where-Object {$_.metric -eq "hypervisor_cpu_usage_ppm"}).values
        $cvm_CPU_Usage = "{0:F2}" -f ($cvm_CPU_Usage[0] / 10000)
        $cvm_mem_Usage = ($CVM_Info.statsSpecificResponses | Where-Object {$_.metric -eq "memory_usage_ppm"}).values
        $cvm_mem_Usage = "{0:F2}" -f ($cvm_mem_Usage[0] / 10000)
        $Query = ""
        $Query = $Query + "INSERT INTO [dbo].[moni_cvm]([ntnx_clu_nm],[cvm_nm],[cpu_usage],[memory_usage],[create_date])"
        $Query = $Query + "VALUES('$clunm','$cvmname','$cvm_CPU_Usage','$cvm_mem_Usage','$dtime')"

        $NoLog = Query-Mssql $Query
    }

    $dplist = Request-RestAPI "protection_domains/" "GET"
    $dplist = $dplist.entities

    foreach($dpinfo in $dplist){
        
        $dpname = $dpinfo.name
        $dpsize = $dpinfo.usage_stats.'dr.exclusive_snapshot_usage_bytes' / 1024 / 1024
        $dpvmcnt = $dpinfo.vms.count
        $dpactive = $dpinfo.active
        write-host $dpname

        $Query = ""
        $Query = $Query + "INSERT INTO [dbo].[moni_dataprotect]([ntnx_clu_nm],[dp_nm],[vm_cnt],[active_status],[snapshot_size],[create_date])"
        $Query = $Query + "VALUES('$clunm','$dpname','$dpvmcnt','$dpactive','$dpsize','$dtime')"

        $NoLog = Query-Mssql $Query

    }
}
