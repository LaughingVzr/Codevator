require 'xcodeproj'
project = Xcodeproj::Project.new('Codevator.xcodeproj')
app = project.new_target(:application, 'Codevator', :osx, '14.0')
tests = project.new_target(:unit_test_bundle, 'CodevatorTests', :osx, '14.0')
tests.add_dependency(app)
ui_tests = project.new_target(:ui_test_bundle, 'CodevatorUITests', :osx, '14.0')
ui_tests.add_dependency(app)
app_group = project.main_group.new_group('Codevator', 'Codevator')
Dir['Codevator/*.swift'].sort.each { |path| app.add_file_references([app_group.new_file(File.basename(path))]) }
app_group.new_file('Assets.xcassets')
icon = app_group.new_file('AppIcon.icns')
app.resources_build_phase.add_file_reference(icon)
test_group = project.main_group.new_group('CodevatorTests', 'CodevatorTests')
Dir['CodevatorTests/*.swift'].sort.each { |path| tests.add_file_references([test_group.new_file(File.basename(path))]) }
ui_test_group = project.main_group.new_group('CodevatorUITests', 'CodevatorUITests')
Dir['CodevatorUITests/*.swift'].sort.each { |path| ui_tests.add_file_references([ui_test_group.new_file(File.basename(path))]) }
package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
package.repositoryURL = 'https://github.com/migueldeicaza/SwiftTerm.git'
package.requirement = { 'kind' => 'exactVersion', 'version' => '1.20.0' }
project.root_object.package_references << package
product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product.package = package
product.product_name = 'SwiftTerm'
app.package_product_dependencies << product
build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
app.frameworks_build_phase.files << build_file
build_file.product_ref = product
[app, tests, ui_tests].each do |target|
  target.build_configurations.each do |config|
    config.build_settings.merge!({ 'SWIFT_VERSION' => '5.0', 'GENERATE_INFOPLIST_FILE' => 'YES', 'CODE_SIGNING_ALLOWED' => 'NO', 'MACOSX_DEPLOYMENT_TARGET' => '14.0', 'ARCHS' => '$(ARCHS_STANDARD)', 'PRODUCT_BUNDLE_IDENTIFIER' => (target == app ? "dev.codeelevator.CodeElevator" : "dev.codeelevator.#{target.name}"), 'SWIFT_EMIT_LOC_STRINGS' => 'YES' })
  end
end
ui_tests.build_configurations.each do |config|
  config.build_settings['TEST_TARGET_NAME'] = 'Codevator'
end
app.build_configurations.each do |config|
  config.build_settings.merge!({ 'INFOPLIST_KEY_LSApplicationCategoryType' => 'public.app-category.developer-tools', 'INFOPLIST_KEY_CFBundleDisplayName' => 'Codevator', 'INFOPLIST_FILE' => 'Codevator/Info.plist', 'MARKETING_VERSION' => '1.0', 'CURRENT_PROJECT_VERSION' => '2', 'ENABLE_APP_SANDBOX' => 'NO', 'COMBINE_HIDPI_IMAGES' => 'YES' })
end
tests.build_configurations.each do |config|
  config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Codevator.app/Contents/MacOS/Codevator'
  config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as('Codevator.xcodeproj', 'Codevator', true)
ui_scheme = Xcodeproj::XCScheme.new
ui_scheme.add_build_target(app)
ui_scheme.add_test_target(ui_tests)
ui_scheme.set_launch_target(app)
ui_scheme.save_as('Codevator.xcodeproj', 'Codevator-UI', true)
