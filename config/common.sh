# shellcheck shell=bash
#
# common.sh — stage bodies + defaults shared by BOTH onboarding modes. Sourced by config/stages-greenfield.sh
# and config/stages-brownfield.sh, never directly. These are exactly the platform bring-up stages: NVCM +
# Nautobot + the Rafay layer, with NO site data. rafay_nvcm_poc's onboarding/README.md ("STC Onboarding — the
# front door") puts it precisely: greenfield and brownfield differ only in HOW the SoT gets filled and the
# deploy posture — both need the platform itself to exist first, and both converge on the same downstream
# render → diff → deploy.

: "${SITE:=blr-dc01}"              # the site name; what changes between modes is how its SoT gets filled
: "${TENANTS:=3-11,84-100}"        # simulate_dc.sh's own default; also what provision_site.sh --tenants reconciles

stage_host_prep(){           bash deploy_scripts/platform/nvcm-host-prep.sh; }   # group changes apply from the next stage (new login)
stage_platform_install_1(){  bash deploy_scripts/platform/platform_install.sh nvcm --yes; }
stage_platform_install_2(){  bash deploy_scripts/platform/platform_install.sh rafay --platform-only --yes; }
stage_verify_platform(){     bash deploy_scripts/platform/verify_platform_install.sh all; }
