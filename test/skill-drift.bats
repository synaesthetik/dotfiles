#!/usr/bin/env bats
#
# Stow is one-directional: it projects repo -> $HOME and has no opinion about
# anything that appears in $HOME on its own. Claude Code writes new skills
# straight into ~/.claude/skills/ as real directories, so a skill authored on
# this machine never reaches the repo and is silently lost on the next one.
# `dot doctor` only ever walked repo -> $HOME, so it could not see that class
# of drift at all.
#
# These specs cover the reverse direction: detecting untracked skills, and
# adopting one into the repo.

setup() {
  REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SKILLS_HOME="$HOME/.claude/skills"
  # Names are test-scoped so a failure can never touch a real skill.
  PROBE="zzz-dot-test-probe-skill"
  PROBE_IGNORED="gsd-zzz-dot-test-probe"
}

teardown() {
  rm -rf "${SKILLS_HOME:?}/$PROBE" "${SKILLS_HOME:?}/$PROBE_IGNORED"
  rm -rf "${REPO_DIR:?}/claude/skills/$PROBE"
}

make_live_skill() {
  local name="$1"
  mkdir -p "$SKILLS_HOME/$name/scripts"
  printf -- '---\nname: %s\n---\nprobe body\n' "$name" > "$SKILLS_HOME/$name/SKILL.md"
  printf '#!/usr/bin/env bash\necho probe\n' > "$SKILLS_HOME/$name/scripts/run.sh"
  chmod +x "$SKILLS_HOME/$name/scripts/run.sh"
}

skip_if_no_claude_skills() {
  [ -d "$SKILLS_HOME" ] || skip "no ~/.claude/skills on this machine"
}

@test "dot doctor names a skill that exists in \$HOME but is untracked in the repo" {
  skip_if_no_claude_skills
  make_live_skill "$PROBE"

  run "$REPO_DIR/bin/dot" doctor
  echo "$output" | grep -qF "$PROBE" || {
    echo "expected doctor to name the untracked skill '$PROBE', got: $output" >&2
    return 1
  }
}

@test "dot doctor exits non-zero when an untracked skill is present" {
  skip_if_no_claude_skills
  make_live_skill "$PROBE"

  run "$REPO_DIR/bin/dot" doctor
  [ "$status" -ne 0 ]
}

@test "dot doctor ignores skills matching a pattern in claude/skills-ignore" {
  skip_if_no_claude_skills
  make_live_skill "$PROBE_IGNORED"

  # gsd-* skills are installed and updated by the GSD installer, not by this
  # repo; nagging about them every run would train the warning to be ignored.
  grep -qF 'gsd-' "$REPO_DIR/claude/skills-ignore"

  run "$REPO_DIR/bin/dot" doctor
  ! echo "$output" | grep -qF "$PROBE_IGNORED"
}

@test "dot doctor does not flag skills already tracked in the repo" {
  skip_if_no_claude_skills

  run "$REPO_DIR/bin/dot" doctor
  for tracked in dsm-validate incremental-release my-voice stacked-release; do
    ! echo "$output" | grep -qE "untracked.*$tracked" || {
      echo "tracked skill '$tracked' was reported as untracked: $output" >&2
      return 1
    }
  done
}

@test "dot adopt moves a live skill into the repo and replaces it with symlinks" {
  skip_if_no_claude_skills
  make_live_skill "$PROBE"

  run "$REPO_DIR/bin/dot" adopt "$PROBE"
  [ "$status" -eq 0 ]

  # Content landed in the repo...
  [ -f "$REPO_DIR/claude/skills/$PROBE/SKILL.md" ]
  [ -f "$REPO_DIR/claude/skills/$PROBE/scripts/run.sh" ]
  grep -qF 'probe body' "$REPO_DIR/claude/skills/$PROBE/SKILL.md"

  # ...and $HOME now points at it rather than holding real files.
  [ -L "$SKILLS_HOME/$PROBE/SKILL.md" ]
  case "$(readlink -f "$SKILLS_HOME/$PROBE/SKILL.md")" in
    "$REPO_DIR"/claude/skills/"$PROBE"/*) : ;;
    *)
      echo "expected \$HOME SKILL.md to resolve into the repo, got $(readlink -f "$SKILLS_HOME/$PROBE/SKILL.md")" >&2
      return 1
      ;;
  esac
}

@test "dot adopt preserves the executable bit on adopted scripts" {
  skip_if_no_claude_skills
  make_live_skill "$PROBE"

  "$REPO_DIR/bin/dot" adopt "$PROBE"
  [ -x "$REPO_DIR/claude/skills/$PROBE/scripts/run.sh" ]
}

@test "dot adopt makes the skill invisible to doctor's untracked check" {
  skip_if_no_claude_skills
  make_live_skill "$PROBE"

  "$REPO_DIR/bin/dot" adopt "$PROBE"

  run "$REPO_DIR/bin/dot" doctor
  ! echo "$output" | grep -qE "untracked.*$PROBE"
}

@test "dot adopt refuses a skill that does not exist in \$HOME" {
  skip_if_no_claude_skills

  run "$REPO_DIR/bin/dot" adopt "definitely-not-a-real-skill-xyz"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE 'not found|does not exist'
}

@test "dot adopt refuses a skill that is already tracked, without touching it" {
  skip_if_no_claude_skills

  run "$REPO_DIR/bin/dot" adopt "my-voice"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE 'already tracked|already managed'

  # The real skill must be completely unharmed by the refusal.
  [ -f "$REPO_DIR/claude/skills/my-voice/SKILL.md" ]
  [ -L "$SKILLS_HOME/my-voice/SKILL.md" ]
}

@test "dot adopt refuses a skill that is its own git clone" {
  skip_if_no_claude_skills
  make_live_skill "$PROBE"
  git -C "$SKILLS_HOME/$PROBE" init -q

  run "$REPO_DIR/bin/dot" adopt "$PROBE"
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE 'git repo|nested git|clone'

  # Copying it in would either vendor a third-party repo or leave a 160000
  # gitlink under claude/skills/, which post-stow.bats explicitly forbids.
  [ ! -e "$REPO_DIR/claude/skills/$PROBE" ]
  [ -f "$SKILLS_HOME/$PROBE/SKILL.md" ]
}

@test "dot adopt with no argument exits non-zero" {
  run "$REPO_DIR/bin/dot" adopt
  [ "$status" -ne 0 ]
}

@test "dot help lists the adopt subcommand" {
  run "$REPO_DIR/bin/dot" help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qw adopt
}
