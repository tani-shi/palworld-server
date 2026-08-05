TF = terraform -chdir=infra

# Never call aws without this. Dropping --region falls back to the default
# profile, which points at another region, and SSM then answers
# TargetNotConnected -- indistinguishable from a broken agent. AWS_REGION in the
# environment does not override the profile either.
AWS = aws --region $(shell $(TF) output -raw aws_region)

# Lazy on purpose: ":=" would run terraform on every invocation, including help,
# and fail before the state exists.
INSTANCE   = $(shell $(TF) output -raw instance_id)
VOLUME     = $(shell $(TF) output -raw root_volume_id)
SG         = $(shell $(TF) output -raw security_group_id)
SECRET     = $(shell $(TF) output -raw server_secrets_parameter)
GAME_PORT  = $(shell $(TF) output -raw game_port)
QUERY_PORT = $(shell $(TF) output -raw query_port)

SAVES       = /home/palworld/PalServer/Pal/Saved
CLONE       = /mnt/restore
DROP_IN_DIR = /etc/systemd/system/palworld.service.d
DROP_IN     = $(DROP_IN_DIR)/no-update.conf

DESC ?= manual

# SSM has no synchronous form, so a command is sent, awaited, then read back.
#
# Two characters must stay out of the argument. A comma would be read as another
# $(call) argument, so chain shell commands with && instead. A single quote would
# close the quoting around --parameters below and hand the rest of the command to
# the local shell, so quote with \" -- JSON turns it back into a plain quote for
# the shell on the box.
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

.DEFAULT_GOAL := help

# Prerequisite of everything that talks to the box. Without it a stopped
# instance answers InvalidInstanceId and a booting one answers
# TargetNotConnected, neither of which says which of the two happened. Reaching
# the agent also takes about 90 seconds after the instance reports running, so
# the state alone is not enough to go on.
require-ssm:
	@test "$$($(AWS) ssm describe-instance-information \
	  --filters Key=InstanceIds,Values=$(INSTANCE) \
	  --query 'InstanceInformationList[0].PingStatus' --output text)" = Online \
	  || { echo "not reachable over SSM; the instance is $$($(AWS) ec2 describe-instances \
	    --instance-ids $(INSTANCE) --query 'Reservations[0].Instances[0].State.Name' \
	    --output text) -- run make start, or wait for the agent if it just booted"; exit 1; }

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"} \
	  /^##@/ {printf "\n%s\n", substr($$0, 5)} \
	  /^[a-z][a-z0-9-]*:.*##/ {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

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
bot: ## Build the Lambda package and deploy it
	bot/scripts/build.sh
	$(TF) apply

bot-commands: ## Register the slash commands with Discord (needs bot/.env)
	cd bot && uv run --env-file .env scripts/deploy_commands.py

##@ Server -- players use /palworld in Discord; these are for when it is unreachable
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

no-update: require-ssm ## Stop app_update from running on the next start
	@$(call ssm,"mkdir -p $(DROP_IN_DIR) && echo \"[Service]\" > $(DROP_IN) && echo \"ExecStartPre=\" >> $(DROP_IN) && systemctl daemon-reload && echo disabled")

no-update-off: require-ssm ## Let app_update run on start again
	@$(call ssm,"rm -f $(DROP_IN) && systemctl daemon-reload && echo enabled")

##@ Snapshots
snapshots: ## List the snapshots of the world volume
	@$(AWS) ec2 describe-snapshots --owner-ids self \
	  --filters Name=volume-id,Values=$(VOLUME) \
	  --query 'reverse(sort_by(Snapshots, &StartTime))[].[SnapshotId,StartTime,State,Description]' \
	  --output table

snapshot: ## Take a snapshot now (DESC="before the update")
	@$(AWS) ec2 create-snapshot --volume-id $(VOLUME) --description "$(DESC)" \
	  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=palworld-manual},{Key=Project,Value=palworld}]' \
	  --query '[SnapshotId,State]' --output text

##@ Restore
# require-ssm is what keeps this off a stopped instance, which matters more here
# than elsewhere: the clone carries the root volume's filesystem UUID, so a boot
# with it attached can mount the clone as root and run the server from it.
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

.PHONY: help require-ssm init fmt plan apply bot bot-commands status start stop \
	allowlist allow revoke session logs password no-update no-update-off \
	snapshots snapshot restore-attach restore-list restore-world restore-clean
