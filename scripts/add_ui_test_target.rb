require 'xcodeproj'

PROJECT_PATH = 'feedmine.xcodeproj'
TEST_DIR = 'feedmineUITests'
TEST_FILE = "#{TEST_DIR}/FeedmineUITests.swift"
INFO_PLIST = "#{TEST_DIR}/Info.plist"
TARGET_NAME = 'feedmineUITests'
APP_TARGET_NAME = 'feedmine'

project = Xcodeproj::Project.open(PROJECT_PATH)

# --- 1. Create the UI test file if it doesn't exist ---
FileUtils.mkdir_p(TEST_DIR)

File.write(INFO_PLIST, <<~PLIST)
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST

# --- 2. Find or create the group ---
main_group = project.main_group.find_subpath(TEST_DIR, true)
main_group.set_source_tree('SOURCE_ROOT')
main_group.set_path(TEST_DIR)

# Add files to group if not already present
info_plist_ref = main_group.new_file(INFO_PLIST) unless main_group.files.any? { |f| f.path == INFO_PLIST }
test_file_ref = main_group.new_file(TEST_FILE) unless main_group.files.any? { |f| f.path == TEST_FILE }

# --- 3. Create the UI test target ---
unless project.targets.any? { |t| t.name == TARGET_NAME }
  test_target = project.new_target(:ui_test_bundle, TARGET_NAME, :ios, nil, nil, nil)
  test_target.product_reference.name = "#{TARGET_NAME}.xctest"
  test_target.product_reference.path = "#{TARGET_NAME}.xctest"

  # Add dependency on the app target
  app_target = project.targets.find { |t| t.name == APP_TARGET_NAME }
  test_target.add_dependency(app_target) if app_target

  # Add source build phase with the test file
  test_target.add_file_references([test_file_ref]) if test_file_ref

  # Configure build settings
  test_target.build_configurations.each do |config|
    config.build_settings['INFOPLIST_FILE'] = INFO_PLIST
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.feedmine.uitests'
    config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
    config.build_settings['SWIFT_VERSION'] = '5.0'
    config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
    config.build_settings['TEST_TARGET_NAME'] = APP_TARGET_NAME
    config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.0'
  end
end

# --- 4. Add test target to scheme ---
scheme_path = "feedmine.xcodeproj/xcshareddata/xcschemes/feedmine.xcscheme"
if File.exist?(scheme_path)
  require 'rexml/document'
  scheme_doc = REXML::Document.new(File.read(scheme_path))
  test_action = scheme_doc.root.elements['TestAction']
  if test_action
    testables = test_action.elements['Testables']
    unless testables.elements.any? { |e| e.attributes['BuildableName']&.include?(TARGET_NAME) }
      # Add TestReference
      tr = testables.add_element('TestableReference', { 'skipped' => 'NO' })
      br = tr.add_element('BuildableReference',
        'BuildableIdentifier' => 'primary',
        'BlueprintIdentifier' => project.targets.find { |t| t.name == TARGET_NAME }&.uuid.to_s,
        'BuildableName' => "#{TARGET_NAME}.xctest",
        'BlueprintName' => TARGET_NAME,
        'ReferencedContainer' => "container:feedmine.xcodeproj"
      )
    end
    # Preserve: must save with single quotes for attributes (Xcode convention)
    File.write(scheme_path, scheme_doc.to_s)
  end
end

project.save
puts "Done: UI test target '#{TARGET_NAME}' added to project."
