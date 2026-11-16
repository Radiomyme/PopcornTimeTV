#!/usr/bin/ruby
# Declares files in PopcornTime.xcodeproj (the project has no folder-synchronised groups: every
# file must be listed). Uses the xcodeproj gem of the SYSTEM Ruby (the one CocoaPods runs on):
#
#   /usr/bin/ruby tools/pbx-add.rb [options]...        (from the repository root)
#
#   --kit REL             a new PopcornKit source (PopcornKit/Managers/Home/HomeFeed.swift):
#                         member of PopcornKit tvOS, PopcornKit iOS and PopcornKit macOS
#   --test REL            a new test file (PopcornTimeTests/<Folder>/<File>.swift):
#                         member of PopcornTimeTests
#   --app TARGETS REL     a new app source; TARGETS is a comma-separated list of tvOS, iOS, Mac,
#                         TopShelf, Tests (or exact target names)
#   --member TARGETS REL  a source ALREADY in the project becomes a member of more targets
#                         (e.g. --member iOS "PopcornTime/UI/Shared SwiftUI/Glass/GlassKit.swift",
#                          --member Tests PopcornTime/Resources/Playback/X.swift)
#   --resource TARGETS REL  a new or existing file goes to the Resources phase of the targets
#   --resource-group TARGETS NAME  an existing variant group (e.g. Localizable.strings) goes to
#                         the Resources phase of the targets
#   --remove REL          a file leaves the project: its reference and its memberships in every
#                         target are removed (the file itself is yours to delete, before or after)
#   --dry-run             print what would change, do not save
#
# Every path is relative to the repository root; references are written with
# sourceTree = SOURCE_ROOT and the full relative path, like the existing entries. Running the
# script twice changes nothing the second time. Check with:
#   git diff --stat PopcornTime.xcodeproj/project.pbxproj     (lines added, none removed)
require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)
project = Xcodeproj::Project.open(File.join(ROOT, 'PopcornTime.xcodeproj'))

ALIASES = {
  'tvOS' => 'PopcornTimetvOS', 'iOS' => 'PopcornTimeiOS', 'Mac' => 'PopcornTimeMac',
  'TopShelf' => 'TopShelf', 'Tests' => 'PopcornTimeTests',
  'KittvOS' => 'PopcornKit tvOS', 'KitiOS' => 'PopcornKit iOS', 'KitMac' => 'PopcornKit macOS'
}.freeze
KIT = ['PopcornKit tvOS', 'PopcornKit iOS', 'PopcornKit macOS'].freeze

find_target = lambda do |name|
  real = ALIASES[name] || name
  project.targets.find { |t| t.name == real } or abort("pbx-add: no target named #{real}")
end
targets_of = ->(list) { list.split(',').map(&:strip).reject(&:empty?).map { |n| find_target.(n) } }

def child_group(parent, name)
  parent.children.find { |c| c.isa == 'PBXGroup' && c.display_name == name } ||
    parent.new_group(name).tap { |g| g.source_tree = '<group>' }
end

# The group that mirrors the file's folder (created when missing); only cosmetic, since the
# reference carries its full path.
def group_for(project, rel)
  File.dirname(rel).split('/').reject { |p| p == '.' }.inject(project.main_group) { |g, name| child_group(g, name) }
end

def existing_reference(project, rel)
  wanted = File.join(ROOT, rel)
  project.files.find { |f| f.real_path.to_s == wanted }
end

def reference(project, rel)
  abort("pbx-add: #{rel} does not exist on disk") unless File.exist?(File.join(ROOT, rel))
  existing_reference(project, rel) || begin
    ref = group_for(project, rel).new_reference(rel)
    ref.source_tree = 'SOURCE_ROOT'
    ref.path = rel
    ref.name = File.basename(rel)
    ref
  end
end

changes = []
add_source = lambda do |target, ref|
  next if target.source_build_phase.files_references.include?(ref)
  target.source_build_phase.add_file_reference(ref)
  changes << "#{target.name}: + #{ref.display_name} (Sources)"
end
add_resource = lambda do |target, ref|
  next if target.resources_build_phase.files_references.include?(ref)
  target.resources_build_phase.add_file_reference(ref)
  changes << "#{target.name}: + #{ref.display_name} (Resources)"
end

dry_run = false
args = ARGV.dup
abort(File.read(__FILE__)[/\A(?:#.*\n)+/]) if args.empty?
until args.empty?
  flag = args.shift
  case flag
  when '--dry-run' then dry_run = true
  when '--kit'
    rel = args.shift or abort('pbx-add: --kit needs a path')
    ref = reference(project, rel)
    KIT.each { |n| add_source.(find_target.(n), ref) }
  when '--test'
    rel = args.shift or abort('pbx-add: --test needs a path')
    abort("pbx-add: #{rel}: expected PopcornTimeTests/...") unless rel.start_with?('PopcornTimeTests/')
    add_source.(find_target.('PopcornTimeTests'), reference(project, rel))
  when '--app'
    list = args.shift; rel = args.shift or abort('pbx-add: --app needs TARGETS and a path')
    ref = reference(project, rel)
    targets_of.(list).each { |t| add_source.(t, ref) }
  when '--member'
    list = args.shift; rel = args.shift or abort('pbx-add: --member needs TARGETS and a path')
    ref = existing_reference(project, rel) or abort("pbx-add: #{rel} is not in the project (use --app for a new file)")
    targets_of.(list).each { |t| add_source.(t, ref) }
  when '--resource'
    list = args.shift; rel = args.shift or abort('pbx-add: --resource needs TARGETS and a path')
    ref = reference(project, rel)
    targets_of.(list).each { |t| add_resource.(t, ref) }
  when '--remove'
    rel = args.shift or abort('pbx-add: --remove needs a path')
    ref = existing_reference(project, rel)
    if ref
      owners = project.targets.select { |t| t.build_phases.any? { |ph| ph.files_references.include?(ref) } }
      ref.remove_from_project
      changes << "- #{rel} (#{owners.empty? ? 'no target' : owners.map(&:name).join(', ')})"
    end
  when '--resource-group'
    list = args.shift; name = args.shift or abort('pbx-add: --resource-group needs TARGETS and a name')
    groups = project.objects.select { |o| o.isa == 'PBXVariantGroup' && o.display_name == name }
    abort("pbx-add: no variant group named #{name}") if groups.empty?
    abort("pbx-add: #{groups.size} variant groups named #{name}: add it by hand") if groups.size > 1
    targets_of.(list).each { |t| add_resource.(t, groups.first) }
  else abort("pbx-add: unknown option #{flag}")
  end
end

if changes.empty?
  puts 'pbx-add: nothing to change'
else
  puts changes
  project.save unless dry_run
  puts(dry_run ? 'pbx-add: dry run, project not saved' : 'pbx-add: project saved')
end
