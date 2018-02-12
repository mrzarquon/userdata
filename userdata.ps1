<powershell>
############################
# Configuration parameters #
############################

# Required environment variables
$env:PUPPET_SERVER_NAME = "example" # Name of your Puppet Enterprise Server
$env:PUPPET_SERVER_FQDN = "example.eu-west-1.opsworks-cm.io"
$env:REGION = "eu-west-1" # Region of Puppet Enterprise Server (us-east-1, us-west-1 or eu-west-1)
$env:PP_INSTANCE_ID = "$(Invoke-WebRequest http://169.254.169.254/latest/meta-data/instance-id)" # Use EC2 Instance ID as Puppet Enterprise Node Name
$env:DAEMONSPLAY = 'true'
$env:SPLAYLIMIT = '10' #this sets the maximum random wait in seconds

##########################################
# Do not modify anything below this line #
##########################################
$env:PP_IMAGE_NAME = "$(Invoke-WebRequest http://169.254.169.254/latest/meta-data/ami-id)"
$env:AVZ = "$(Invoke-WebRequest http://169.254.169.254/latest/meta-data/placement/availability-zone)"
$env:PP_REGION = $env:AVZ.Substring(0,$env:AVZ.Length-1)
$puppet_bin_dir  = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Puppet Labs\Puppet\bin'
$puppet_conf_dir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Puppetlabs\puppet\etc'
$puppet_modules_dir = Join-Path $puppet_conf_dir 'modules'
$puppet_ssl_dir  = Join-Path $puppet_conf_dir 'ssl'
$puppet_certs_dir  = Join-Path $puppet_ssl_dir 'certs'
$cert_path       = Join-Path $puppet_certs_dir 'ca.pem'

New-Alias aws "C:\Program Files\Amazon\AWSCLI\aws.exe"
New-Alias puppet "$puppet_bin_dir\puppet.bat"

function download_with_retries {
   $stop_try = $false
   $retry_count = 1
   $uri = $args[0]
   $outfile = $args[1]
   $name_of_dl = $args[2]
   $max_retries = 5
   $retry_sleep = 10
   do {
       try {
           Invoke-WebRequest -Uri "$uri" -OutFile $outfile
           Write-Host "Successfully downloaded the $name_of_dl"
           $stop_try = $true
       }
       catch {
           if ($retry_count -gt $max_retries) {
               Write-Host "Tried $max_retries times, all failed! Check your connectivity"
               $stop_try = $true
               exit 1
           } else {
               Write-Host "Failed to download $name_of_dl - retrying after $retry_sleep seconds..."
               Start-Sleep -Seconds $retry_sleep
               $retry_count = $retry_count + 1
           }
       }
   }
   while ($stop_try -eq $false)
}

function install_aws_cli {
  Write-Host "Checking for AWS CLI..."
  aws --version
  if (-not ($?)){
    Write-Host "AWS CLI not found, installing..."
    download_with_retries "https://s3.amazonaws.com/aws-cli/AWSCLI64.msi" "awscli.msi" "AWS CLI Installation"
    Start-Process msiexec -ArgumentList "/qn /i awscli.msi" -wait
  }
}

function create_puppet_directories {
  Write-Host "Creating Puppet base directories..."
  New-Item -ItemType Directory -Path $puppet_modules_dir -Force
  New-Item -ItemType Directory -Path $puppet_ssl_dir -Force
  New-Item -ItemType Directory -Path $puppet_certs_dir -Force
}

function retrieve_puppet_ca {
  Write-Host "Retrieving CA certificate from $env:PUPPET_SERVER_NAME"
  $ca_cert_contents = aws opsworks-cm --region $env:REGION --output text describe-servers --server-name $env:PUPPET_SERVER_NAME --query "Servers[0].EngineAttributes[?Name=='PUPPET_API_CA_CERT'].Value"
  Out-File -FilePath $cert_path -InputObject $ca_cert_contents -Encoding ASCII
}

function generate_csr_attributes {
  Write-Host "Parsing Tags for SSl Extensions..."
  $tags = aws ec2 --region=$env:REGION describe-tags --filters """Name=resource-id,Values=$env:PP_INSTANCE_ID""" --query 'Tags[?starts_with(Key, `pp_`)].[Key,Value]' --output text

  $csr_attr="extension_requests:pp_instance_id=$env:PP_INSTANCE_ID extension_requests:pp_region=$env:REGION extension_requests:pp_image_name=$env:PP_IMAGE_NAME"

  foreach ($tag in $tags){
    $pp_name = $tag.split("`t")[0]
    $pp_value = $tag.split("`t")[1]
    $csr_attr = "extension_requests:$pp_name=$pp_value $csr_attr "
  }

  return $csr_attr.trim()
}


$callback = {
 param(
     $sender,
     [System.Security.Cryptography.X509Certificates.X509Certificate]$certificate,
     [System.Security.Cryptography.X509Certificates.X509Chain]$chain,
     [System.Net.Security.SslPolicyErrors]$sslPolicyErrors
 )

 $CertificateType = [System.Security.Cryptography.X509Certificates.X509Certificate2]

 # Read the CA cert from file
 $CACert = $CertificateType::CreateFromCertFile($cert_path) -as $CertificateType

 # Add cert to collection of certificates that is searched by
 # the chaining engine when validating the certificate chain.
 $chain.ChainPolicy.ExtraStore.Add($CACert) | Out-Null

 # Compare the cert on disk to the cert from the server
 $chain.Build($certificate) | Out-Null

 # If the first status is UntrustedRoot, then it's a self signed cert
 # Anything else in this position means it failed for another reason
 return $chain.ChainStatus[0].Status -eq [System.Security.Cryptography.X509Certificates.X509ChainStatusFlags]::UntrustedRoot
}

function install_puppet_with_ca {
  Write-Host "Installing Puppet Agent"
  $ps1_source = "https://$($env:PUPPET_SERVER_FQDN):8140/packages/current/install.ps1"
  [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $callback
  $webclient = New-Object system.net.webclient

  try {
    $webclient.DownloadFile($ps1_source,'install.ps1')
  }
  catch [System.Net.WebException] {
    # If we can't find the msi, then we may not be configured correctly
    if($_.Exception.Response.StatusCode -eq [system.net.httpstatuscode]::NotFound) {
      Throw "Failed to download the Puppet Agent installer script: $ps1_source."
  }

  # Throw all other WebExceptions in case the cert did not validate properly
  Throw $_
  }
  # this breaks here for some reason
  .\install.ps1 agent:certname=$env:PP_INSTANCE_ID agent:splay=$env:DAEMONSPLAY $(generate_csr_attributes) -UsePuppetCA -PuppetServiceEnsure stopped -PuppetServiceEnable false

  Write-Host "Puppet Agent installed"
}

function download_puppet_bootstrap {
  # because we break trust in web downloads for the PE install as part of this runtime, we're downloading this regardless of if it is installed
  # until i can think of a better idea
  download_with_retries "https://s3.amazonaws.com/opsworks-cm-us-east-1-prod-default-assets/misc/owpe/puppet-agent-bootstrap-0.2.1.tar.gz" "puppet-agent-bootstrap.tar.gz" "Puppet Agent Bootstrap"
}

function install_puppet_bootstrap {
  Write-Host "Checking for Puppet Bootstrap App..."
  puppet help bootstrap
  if (-not ($?)){
    Write-Host "Puppet Bootstrap not found, installing..."
    # see download_puppet_bootstrap
    puppet module install puppet-agent-bootstrap.tar.gz --ignore-dependencies
  }
}

function associatenode {
  Write-Host "Generating Puppet Certificate"
  $CERTNAME = puppet config print certname --section agent

  puppet bootstrap purge
  puppet bootstrap csr

  $PP_CSR_PATH = Join-Path $puppet_ssl_dir "certificate_requests/$CERTNAME.pem"
  $PP_CERT_PATH = Join-Path $puppet_certs_dir "$CERTNAME.pem"
  $CSR_CONTENT = (Get-Content -Path $PP_CSR_PATH) -join "`n"

  Write-Host "Submitting Puppet Certificate"
  $ASSOCIATE_TOKEN = $(aws opsworks-cm --region $env:REGION associate-node --server-name $env:PUPPET_SERVER_NAME --node-name $CERTNAME --engine-attributes "Name=PUPPET_NODE_CSR,Value=$($CSR_CONTENT)" --query "NodeAssociationStatusToken" --output text)

  #wait
  Write-Host "Waiting on OpsWorks for Puppet Certificate"
  aws opsworks-cm --region $env:REGION wait node-associated --node-association-status-token "$ASSOCIATE_TOKEN" --server-name $env:PUPPET_SERVER_NAME
  #install and verify
  Write-Host "Writing Puppet Certificate"
  $signed_cert_contents = aws opsworks-cm --region $env:REGION describe-node-association-status --node-association-status-token "$ASSOCIATE_TOKEN" --server-name $env:PUPPET_SERVER_NAME --query 'EngineAttributes[0].Value' --output text
  Out-File -FilePath $PP_CERT_PATH -InputObject $signed_cert_contents -Encoding ASCII

  Write-Host "Validating Puppet Certificate"
  puppet bootstrap verify
}

function runpuppet {
  $sleep_time = Get-Random -Minimum 0 -Maximum $env:SPLAYLIMIT
  Write-Host "Starting Puppet Agent after $sleep_time second wait"

  Start-Sleep -s $sleep_time

  puppet agent --enable
  puppet agent --onetime --no-daemonize --no-usecacheonfailure --no-splay --verbose
  puppet resource service puppet ensure=running enable=true
}

install_aws_cli
download_puppet_bootstrap
create_puppet_directories
retrieve_puppet_ca
install_puppet_with_ca
install_puppet_bootstrap
associatenode
runpuppet
</powershell>
