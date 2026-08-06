TF = terraform -chdir=infra

# Never call aws without this. Without --region the CLI uses the default
# profile's region, which is not this one, and SSM then answers
# TargetNotConnected as if the agent were broken. AWS_REGION does not override
# the profile.
AWS = aws --region $(shell $(TF) output -raw aws_region)

# Lazy on purpose: ":=" would run terraform on every invocation, including help,
# and fail before the state exists.
INSTANCE   = $(shell $(TF) output -raw instance_id)
VOLUME     = $(shell $(TF) output -raw root_volume_id)
SG         = $(shell $(TF) output -raw security_group_id)
SECRET     = $(shell $(TF) output -raw server_secrets_parameter)
GAME_PORT  = $(shell $(TF) output -raw game_port)
QUERY_PORT = $(shell $(TF) output -raw query_port)
REST_PORT   = $(shell $(TF) output -raw rest_api_port)
MAX_PLAYERS = $(shell $(TF) output -raw max_players)
BUCKET      = $(shell $(TF) output -raw command_output_bucket)
REGION      = $(shell $(TF) output -raw aws_region)
PROMPT_PARAM = $(shell $(TF) output -raw system_prompt_parameter)
PROMPT_FILE  = bot/prompts/ask.md

PAL_DIR     = /home/palworld/PalServer
SAVES       = $(PAL_DIR)/Pal/Saved
CLONE       = /mnt/restore
DROP_IN_DIR = /etc/systemd/system/palworld.service.d
DROP_IN     = $(DROP_IN_DIR)/no-update.conf
GAMEDATA_DROP_IN = $(DROP_IN_DIR)/gamedata-api.conf

DESC ?= manual

# SSM has no synchronous form, so a command is sent, awaited, then read back.
#
# Two characters must stay out of the argument. A comma is read as another
# $(call) argument, so chain shell commands with &&. A single quote closes the
# quoting around --parameters below and hands the rest to the local shell, so
# quote with \" instead; JSON turns it back into a plain quote on the box.
define ssm
A="$(AWS)"; I="$(INSTANCE)"; \
CMD=$$($$A ssm send-command --instance-ids $$I --document-name AWS-RunShellScript \
  --parameters 'commands=[$(1)]' --query Command.CommandId --output text); \
if $$A ssm wait command-executed --command-id $$CMD --instance-id $$I; then \
  $$A ssm get-command-invocation --command-id $$CMD --instance-id $$I \
    --query StandardOutputContent --output text; \
else \
  $$A ssm get-command-invocation --command-id $$CMD --instance-id $$I \
    --query '[StandardOutputContent,StandardErrorContent]' --output text >&2; \
  exit 1; \
fi
endef

# Read on the box so the admin password never reaches this machine. The
# expansion stays inside the single-quoted --parameters below, so the local
# shell leaves it alone and the instance is what evaluates it.
PW   = $$(aws ssm get-parameter --region $(REGION) --name $(SECRET) --with-decryption --query Parameter.Value --output text | jq -r .admin_password)
CURL = curl -fsS -u \"admin:$(PW)\"
API  = http://127.0.0.1:$(REST_PORT)/v1/api

# Same shape as ssm above, but the output comes back through S3. The inline
# StandardOutputContent stops at 24,000 characters and game-data passes that
# with one player online, so reading it inline would silently truncate. All six
# endpoints share this path rather than only the large one: two paths would
# mean remembering which endpoint is safe to read inline. The object key is
# looked up rather than assembled, because the layout Run Command writes under
# the prefix is not part of its API contract.
define restapi
A="$(AWS)"; I="$(INSTANCE)"; B="$(BUCKET)"; \
CMD=$$($$A ssm send-command --instance-ids $$I --document-name AWS-RunShellScript \
  --output-s3-bucket-name $$B --output-s3-key-prefix restapi \
  --parameters 'commands=[$(1)]' --query Command.CommandId --output text); \
if ! $$A ssm wait command-executed --command-id $$CMD --instance-id $$I; then \
  $$A ssm get-command-invocation --command-id $$CMD --instance-id $$I \
    --query StandardErrorContent --output text >&2; \
  exit 1; \
fi; \
KEY=$$($$A s3api list-objects-v2 --bucket $$B --prefix restapi/$$CMD \
  --query "Contents[?ends_with(Key, 'stdout')].Key" --output text); \
test -n "$$KEY" || { echo "the command wrote no stdout" >&2; exit 1; }; \
$$A s3 cp s3://$$B/$$KEY -
endef

.DEFAULT_GOAL := help

# Prerequisite of everything that talks to the box. A stopped instance answers
# InvalidInstanceId and a booting one TargetNotConnected, so the raw errors do
# not say which happened. The agent also needs about 90 seconds after the
# instance reports running, so checking the state alone is not enough.
require-ssm:
	@test "$$($(AWS) ssm describe-instance-information \
	  --filters Key=InstanceIds,Values=$(INSTANCE) \
	  --query 'InstanceInformationList[0].PingStatus' --output text)" = Online \
	  || { echo "not reachable over SSM; the instance is $$($(AWS) ec2 describe-instances \
	    --instance-ids $(INSTANCE) --query 'Reservations[0].Instances[0].State.Name' \
	    --output text). Run make start, or wait for the agent if it just booted"; exit 1; }

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} \
	  /^##@/ {printf "\n%s\n", substr($$0, 5)} \
	  /^[a-z][a-z0-9-]*:.*##/ {printf "  %-21s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ Infra
init: ## Initialise Terraform
	$(TF) init

fmt: ## Format and validate the Terraform
	$(TF) fmt
	$(TF) validate

plan: ## Show what an apply would change
	$(TF) plan

apply: ## Apply the Terraform
	$(TF) apply

##@ Bot
bot-deploy: ## Build the Lambda package and deploy it
	bot/scripts/build.sh
	$(TF) apply

bot-deploy-commands: ## Register the slash commands with Discord (needs bot/.env)
	cd bot && uv run --env-file .env scripts/deploy_commands.py

prompt: ## Show the system prompt the bot is running with
	@$(AWS) ssm get-parameter --name $(PROMPT_PARAM) --query Parameter.Value --output text

prompt-deploy: ## Push bot/prompts/ask.md as the system prompt (no redeploy needed)
	@$(AWS) ssm put-parameter --name $(PROMPT_PARAM) --type String --tier Advanced \
	  --overwrite --value "file://$(PROMPT_FILE)" --query Version --output text

##@ Server (players use /palworld in Discord; these are for when it is unreachable)
status: ## Instance state, address and health checks
	@A="$(AWS)"; I="$(INSTANCE)"; \
	$$A ec2 describe-instances --instance-ids $$I \
	  --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' --output text; \
	$$A ec2 describe-instance-status --instance-ids $$I \
	  --query 'InstanceStatuses[0].[InstanceStatus.Status,SystemStatus.Status]' --output text \
	  | grep -v '^None$$' || true

start: ## Start the instance
	@$(AWS) ec2 start-instances --instance-ids $(INSTANCE) \
	  --query 'StartingInstances[0].CurrentState.Name' --output text

stop: ## Stop the instance
	@$(AWS) ec2 stop-instances --instance-ids $(INSTANCE) \
	  --query 'StoppingInstances[0].CurrentState.Name' --output text

##@ REST API
api-info: require-ssm ## Server version, name and world id
	@$(call restapi,"$(CURL) $(API)/info")

api-metrics: require-ssm ## FPS, player count, uptime, base camps, in-game day
	@$(call restapi,"$(CURL) $(API)/metrics")

api-players: require-ssm ## Players connected right now
	@$(call restapi,"$(CURL) $(API)/players")

api-settings: require-ssm ## Effective server settings
	@$(call restapi,"$(CURL) $(API)/settings")

api-game-data: require-ssm ## Snapshot of every actor in the world
	@$(call restapi,"$(CURL) $(API)/game-data")

# The text is base64'd before it reaches the SSM command string, which can
# carry neither a comma (it would split the $(call) argument) nor a single
# quote (it would close the quoting around --parameters). MSG's own single
# quotes are escaped first: $(shell ...) runs through /bin/sh here, so an
# apostrophe in the message would otherwise break the encoding itself and send
# an empty announcement with no error.
api-announce: require-ssm ## Broadcast a message in game (MSG="server going down")
	@test -n "$(MSG)" || { echo 'usage: make api-announce MSG="text"'; exit 1; }
	@$(call restapi,"echo $(shell printf %s '$(subst ','\'',$(MSG))' | base64 | tr -d '\n') | base64 -d >/tmp/announce.txt && jq -Rs \"{message:.}\" </tmp/announce.txt >/tmp/announce.json && $(CURL) -X POST -H \"Content-Type: application/json\" -d @/tmp/announce.json $(API)/announce; RC=$$?; rm -f /tmp/announce.txt /tmp/announce.json; exit $$RC")

##@ Access
allowlist: ## List the addresses allowed to reach the server
	@$(AWS) ec2 describe-security-groups --group-ids $(SG) \
	  --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text \
	  | tr '\t' '\n' | sort -u

allow: ## Allow an address on both ports (IP=203.0.113.4)
	@test -n "$(IP)" || { echo "usage: make allow IP=<address>"; exit 1; }
	@A="$(AWS)"; G="$(SG)"; \
	$$A ec2 authorize-security-group-ingress --group-id $$G \
	  --protocol udp --port $(GAME_PORT) --cidr $(IP)/32 >/dev/null; \
	$$A ec2 authorize-security-group-ingress --group-id $$G \
	  --protocol udp --port $(QUERY_PORT) --cidr $(IP)/32 >/dev/null; \
	echo "allowed $(IP)"

revoke: ## Revoke an address on both ports (IP=203.0.113.4)
	@test -n "$(IP)" || { echo "usage: make revoke IP=<address>"; exit 1; }
	@A="$(AWS)"; G="$(SG)"; \
	$$A ec2 revoke-security-group-ingress --group-id $$G \
	  --protocol udp --port $(GAME_PORT) --cidr $(IP)/32 >/dev/null; \
	$$A ec2 revoke-security-group-ingress --group-id $$G \
	  --protocol udp --port $(QUERY_PORT) --cidr $(IP)/32 >/dev/null; \
	echo "revoked $(IP)"

##@ Box
session: require-ssm ## Open a shell on the instance
	@$(AWS) ssm start-session --target $(INSTANCE)

logs: require-ssm ## Last 200 lines of the server log
	@$(call ssm,"journalctl -u palworld -n 200 --no-pager")

password: ## Read the in-game admin password
	@$(AWS) ssm get-parameter --name $(SECRET) --with-decryption \
	  --query Parameter.Value --output text

autoupdate-off: require-ssm ## Stop app_update from running on the next start
	@$(call ssm,"mkdir -p $(DROP_IN_DIR) && echo \"[Service]\" > $(DROP_IN) && echo \"ExecStartPre=\" >> $(DROP_IN) && systemctl daemon-reload && echo disabled")

autoupdate-on: require-ssm ## Let app_update run on start again
	@$(call ssm,"rm -f $(DROP_IN) && systemctl daemon-reload && echo enabled")

gamedata-on: require-ssm ## Expose /v1/api/game-data (restarts the game server)
	@$(call ssm,"mkdir -p $(DROP_IN_DIR) && echo \"[Service]\" > $(GAMEDATA_DROP_IN) && echo \"ExecStart=\" >> $(GAMEDATA_DROP_IN) && echo \"ExecStart=$(PAL_DIR)/PalServer.sh -port=$(GAME_PORT) -players=$(MAX_PLAYERS) -useperfthreads -NoAsyncLoadingThread -UseMultithreadForDS -EnableGameDataAPI\" >> $(GAMEDATA_DROP_IN) && systemctl daemon-reload && systemctl restart palworld && echo enabled")

gamedata-off: require-ssm ## Hide /v1/api/game-data again (restarts the game server)
	@$(call ssm,"rm -f $(GAMEDATA_DROP_IN) && systemctl daemon-reload && systemctl restart palworld && echo disabled")

##@ Snapshots
snapshots: ## List the snapshots of the world volume
	@$(AWS) ec2 describe-snapshots --owner-ids self \
	  --filters Name=volume-id,Values=$(VOLUME) \
	  --query 'reverse(sort_by(Snapshots, &StartTime))[].[SnapshotId,StartTime,State,Description]' \
	  --output table

snapshot-create: ## Take a snapshot now (DESC="before the update")
	@$(AWS) ec2 create-snapshot --volume-id $(VOLUME) --description "$(DESC)" \
	  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=palworld-manual},{Key=Project,Value=palworld}]' \
	  --query '[SnapshotId,State]' --output text

##@ Restore
# require-ssm keeps this off a stopped instance. The clone carries the root
# volume's filesystem UUID, so a boot with it attached can mount the clone as
# root and run the server from it.
restore-attach: require-ssm ## Clone a snapshot and mount it read-only (SNAP=snap-...)
	@test -n "$(SNAP)" || { echo "usage: make restore-attach SNAP=<snapshot-id>"; exit 1; }
	@A="$(AWS)"; I="$(INSTANCE)"; \
	AZ=$$($$A ec2 describe-instances --instance-ids $$I \
	  --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text); \
	VOL=$$($$A ec2 create-volume --availability-zone $$AZ --snapshot-id $(SNAP) --volume-type gp3 \
	  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=palworld-restore},{Key=Project,Value=palworld}]' \
	  --query VolumeId --output text); \
	$$A ec2 wait volume-available --volume-ids $$VOL; \
	$$A ec2 attach-volume --instance-id $$I --volume-id $$VOL --device /dev/sdf >/dev/null; \
	$$A ec2 wait volume-in-use --volume-ids $$VOL; \
	sleep 5; \
	echo "attached $$VOL"
	@$(call ssm,"mkdir -p $(CLONE) && mount -o ro /dev/nvme1n1p1 $(CLONE) && echo mounted")

restore-list: require-ssm ## List the worlds inside the mounted clone
	@$(call ssm,"ls -l $(CLONE)$(SAVES)/SaveGames/0/*/Level.sav")

restore-world: require-ssm ## Copy one world out of the clone (WORLD=54A0...)
	@test -n "$(WORLD)" || { echo "usage: make restore-world WORLD=<world-id>"; exit 1; }
	@$(call ssm,"systemctl stop palworld && mv $(SAVES)/SaveGames/0/$(WORLD) $(SAVES)/SaveGames/0/$(WORLD).replaced-$$(date -u +%Y%m%dT%H%M%SZ) && cp -a $(CLONE)$(SAVES)/SaveGames/0/$(WORLD) $(SAVES)/SaveGames/0/ && chown -R palworld:palworld $(SAVES) && systemctl start palworld && echo restored $(WORLD)")

restore-clean: require-ssm ## Unmount the clone and delete it
	@$(call ssm,"umount $(CLONE) && rmdir $(CLONE) && echo unmounted")
	@A="$(AWS)"; I="$(INSTANCE)"; \
	VOL=$$($$A ec2 describe-volumes \
	  --filters Name=attachment.instance-id,Values=$$I Name=attachment.device,Values=/dev/sdf \
	  --query 'Volumes[0].VolumeId' --output text); \
	test "$$VOL" != None || { echo "no clone attached at /dev/sdf"; exit 1; }; \
	$$A ec2 detach-volume --volume-id $$VOL >/dev/null; \
	$$A ec2 wait volume-available --volume-ids $$VOL; \
	$$A ec2 delete-volume --volume-id $$VOL; \
	echo "deleted $$VOL"

.PHONY: help require-ssm init fmt plan apply bot-deploy bot-deploy-commands prompt prompt-deploy status start stop \
	allowlist allow revoke session logs password autoupdate-off autoupdate-on gamedata-on gamedata-off \
	snapshots snapshot-create restore-attach restore-list restore-world restore-clean \
	api-info api-metrics api-players api-settings api-game-data api-announce
