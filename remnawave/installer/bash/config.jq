def ip4:
  type == "string" and test("^(0|[1-9][0-9]{0,2})(\\.(0|[1-9][0-9]{0,2})){3}$") and
  (split(".") | all(tonumber <= 255));
def ip6:
  type == "string" and test("^[a-fA-F0-9:]+$") and
  (split("::") as $halves | ($halves|length) <= 2 and
   ([split(":")[] | select(length > 0)] as $parts |
    ($parts | all(length <= 4)) and
    (if ($halves|length) == 2 then ($parts|length) < 8
     else ($parts|length) == 8 end))) and
  ((startswith(":")|not) or startswith("::")) and
  ((endswith(":")|not) or endswith("::"));
def ip: ip4 or ip6;
def ipnorm:
  if contains(":") then
    ascii_downcase | split("::") as $halves |
    ($halves[0] | split(":") | map(select(length > 0))) as $left |
    (($halves[1] // "") | split(":") | map(select(length > 0))) as $right |
    (if ($halves|length) == 2 then $left + [range(8-($left|length)-($right|length))|"0"] + $right
     else $left end) | map(("0000"+.)|.[-4:]) | join(":")
  else . end;
def domain:
  type == "string" and length <= 253 and contains(".") and
  test("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$") and (ip|not);
def port: type == "number" and . == floor and . >= 1 and . <= 65535;
def require($ok; $message): if $ok then . else error($message) end;
.
| require(type == "object"; "config must be a JSON object")
| require((keys - ["schema_version","environment_id","role","network_mode","domains","public_addresses","panel_addresses","management_address","ports","admin","resources","docker_subnet","acme","node_country","existing_caddy"]) == []; "unknown config field")
| require(.schema_version == 1; "expected config schema_version 1")
| require(.environment_id | type == "string" and test("^[a-z][a-z0-9-]{2,19}$"); "environment_id: 3..20 letters/digits/hyphens")
| require(.role == "panel" or .role == "node" or .role == "panel-node"; "invalid role")
| .network_mode //= "clean"
| require(.network_mode == "clean" or .network_mode == "fi-parallel"; "invalid network_mode")
| require(.network_mode != "fi-parallel" or .role == "panel-node"; "FI parallel requires panel-node")
| .role as $role
| (if $role == "panel" then ["panel","subscription"] elif $role == "node" then ["node"] else ["node","panel","subscription"] end) as $names
| require((.domains|type) == "object" and (.domains|keys) == $names; "wrong domains for role")
| require(.domains | all(.[]; domain); "domains must be lower-case DNS names without URL/path/port")
| require(.public_addresses | type == "array" and length > 0 and all(ip); "public_addresses must contain literal A/AAAA IPs")
| .public_addresses |= (map(ipnorm)|unique)
| .panel_addresses //= []
| require(.panel_addresses | type == "array" and all(ip); "invalid panel_addresses")
| .panel_addresses |= (map(ipnorm)|unique)
| require(($role != "node" and (.panel_addresses|length) == 0) or ($role == "node" and (.panel_addresses|length) > 0); "standalone node requires panel source IPs")
| if $role=="node" then .management_address //= .domains.node | require(.management_address|ip or domain; "invalid node management_address")
  else require(.management_address==null; "management_address belongs to a standalone node") end
| .ports //= {}
| (if $role == "panel" then {http:80,https:443,panel_api:13000,metrics:13001,subscription_api:13010,caddy_admin:12019}
   elif $role == "node" then {http:80,reality:443,xhttp:8443,node_api:2222,reality_target:14123,caddy_admin:12019}
   elif .network_mode == "fi-parallel" then {http:18080,https:9443,panel_api:13000,metrics:13001,subscription_api:13010,reality:24443,xhttp:28443,node_api:2222,reality_target:14123,caddy_admin:12019}
   else {http:80,https:9443,panel_api:13000,metrics:13001,subscription_api:13010,reality:443,xhttp:8443,node_api:2222,reality_target:14123,caddy_admin:12019} end) as $defaults
| (if $role != "node" and .domains.panel == .domains.subscription then $defaults + {subscription_https:9444} else $defaults end) as $defaults
| require((.ports|type) == "object" and ((.ports|keys)-($defaults|keys)) == []; "unknown port for role")
| .ports = ($defaults + .ports)
| require(.ports | all(.[]; port); "ports must be integers 1..65535")
| require((.ports|[.[]]|unique|length) == (.ports|length); "duplicate ports")
| require(.network_mode != "fi-parallel" or ((.ports|[.[]]) - [80,443,8443,37241,4123,53042] | length) == (.ports|length); "FI port reserved by current system")
| .admin //= {}
| require($role == "node" or (.admin.username|type == "string" and test("^[a-z][a-z0-9_-]{2,31}$")); "invalid admin username")
| require($role == "node" or (.admin.email|type == "string" and test("^[A-Za-z0-9._+-]+@[a-z0-9.-]+\\.[a-z]{2,}$")); "invalid admin email")
| require((.admin|keys)-["username","email"] == []; "unknown admin field; no plaintext secrets in config")
| .resources //= {}
| .resources = ({purpose:"test",profile:"standard",image_gib:3,data_gib:1,restore_gib:2,reserve_gib:1} + .resources)
| require(.resources.purpose == "test" or .resources.purpose == "production"; "invalid purpose")
| require(.network_mode != "fi-parallel" or .resources.purpose == "test"; "FI parallel is only a test")
| require(.resources.profile == "standard" or (.resources.profile == "compact-test" and .resources.purpose == "test"); "compact-test profile is only for tests")
| require([.resources.image_gib,.resources.data_gib,.resources.restore_gib,.resources.reserve_gib] | all(type == "number" and . > 0 and . <= 10000); "positive disk budgets required")
| require((.resources|keys)-["purpose","profile","image_gib","data_gib","restore_gib","reserve_gib"] == []; "unknown resources field")
| .docker_subnet //= "172.29.240.0/24"
| require(.docker_subnet | type == "string" and test("^(10\\.[0-9]{1,3}\\.[0-9]{1,3}|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9]{1,3}|192\\.168\\.[0-9]{1,3})\\.0/24$") and (split("/")[0]|ip4); "docker_subnet must be a private IPv4 /24")
| .acme //= "production"
| require(.acme == "production" or .acme == "staging"; "acme must be production or staging")
| .node_country //= "XX"
| require(.node_country | type == "string" and test("^[A-Z]{2}$"); "invalid country code")
