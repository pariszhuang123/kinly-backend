CREATE OR REPLACE FUNCTION public.shopping_list_update_item_v2(
  p_item_id uuid,
  p_name text DEFAULT NULL,
  p_quantity text DEFAULT NULL,
  p_details text DEFAULT NULL,
  p_is_completed boolean DEFAULT NULL,
  p_reference_photo_path text DEFAULT NULL,
  p_replace_photo boolean DEFAULT FALSE,
  p_scope_type text DEFAULT NULL,
  p_unit_id uuid DEFAULT NULL
)
RETURNS public.shopping_list_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN public._shopping_list__update_item_core(
    p_item_id,
    p_name,
    p_quantity,
    p_details,
    p_is_completed,
    p_reference_photo_path,
    p_replace_photo,
    p_scope_type,
    p_unit_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.#394    RendererBinding._handlePersistentFrameCallback (package:flutter/src/rendering/binding.dart:495:5)       
#395    SchedulerBinding._invokeFrameCallback (package:flutter/src/scheduler/binding.dart:1434:15)
#396    SchedulerBinding.handleDrawFrame (package:flutter/src/scheduler/binding.dart:1347:9)
#397    AutomatedTestWidgetsFlutterBinding.pump.<anonymous closure> (package:flutter_test/src/binding.dart:1335:9)
#400    TestAsyncUtils.guard (package:flutter_test/src/test_async_utils.dart:74:41)
#401    AutomatedTestWidgetsFlutterBinding.pump (package:flutter_test/src/binding.dart:1324:27)
#402    WidgetTester.pumpAndSettle.<anonymous closure> (package:flutter_test/src/widget_tester.dart:719:23)     
#405    TestAsyncUtils.guard (package:flutter_test/src/test_async_utils.dart:74:41)
#406    WidgetTester.pumpAndSettle (package:flutter_test/src/widget_tester.dart:712:27)
#407    main.<anonymous closure> (file:///C:/Users/tomzq/StudioProjects/Kinly/kinly/test/app/router/profile_settings_detail_routes_test.dart:160:18)
<asynchronous suspension>
#408    testWidgets.<anonymous closure>.<anonymous closure> (package:flutter_test/src/widget_tester.dart:192:15)
<asynchronous suspension>
#409    TestWidgetsFlutterBinding._runTestBody (package:flutter_test/src/binding.dart:1059:5)
<asynchronous suspension>
<asynchronous suspension>
(elided 5 frames from dart:async and package:stack_trace)

════════════════════════════════════════════════════════════════════════════════════════════════════
00:13 +49 -1: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/app/router/profile_settings_detail_routes_test.dart: create route builds provider when args are present    
══╡ EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK ╞════════════════════════════════════════════════════
The following TestFailure was thrown running a test:    
Expected: exactly 2 matching candidates
  Actual: _TextWidgetFinder:<Found 0 widgets with text "Create shared unit": []>
   Which: means none were found but some were expected  

When the exception was thrown, this was the stack:      
#4      main.<anonymous closure> (file:///C:/Users/tomzq/StudioProjects/Kinly/kinly/test/app/router/profile_settings_detail_routes_test.dart:162:5)
<asynchronous suspension>
#5      testWidgets.<anonymous closure>.<anonymous closure> (package:flutter_test/src/widget_tester.dart:192:15)
<asynchronous suspension>
#6      TestWidgetsFlutterBinding._runTestBody (package:flutter_test/src/binding.dart:1059:5)
<asynchronous suspension>
<asynchronous suspension>
(elided one frame from package:stack_trace)

This was caught by the test expectation on the following line:
  file:///C:/Users/tomzq/StudioProjects/Kinly/kinly/test/app/router/profile_settings_detail_routes_test.dart line 162
The test description was:
  create route builds provider when args are present    
════════════════════════════════════════════════════════════════════════════════════════════════════
══╡ EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK ╞════════════════════════════════════════════════════
The following message was thrown:
Multiple exceptions (2) were detected during the running of the current test, and at least one was
unexpected.
════════════════════════════════════════════════════════════════════════════════════════════════════
00:13 +49 -2: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/app/router/profile_settings_detail_routes_test.dart: create route builds provider when args are present [E]
  Test failed. See exception logs above.
  The test description was: create route builds provider when args are present


To run this test again: C:\flutter\bin\cache\dart-sdk\bin\dart.exe test C:/Users/tomzq/StudioProjects/Kinly/kinly/test/app/router/profile_settings_detail_routes_test.dart -p vm --plain-name "create route builds provider when args are present"
00:26 +290 -3: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/contracts/share/models_test.dart: TodayShareOwedItem props contains all fields [E]
  Expected: an object with length of <8>
    Actual: [
              'exp-1',
              'Groceries',
              2500,
              1,
              ExpenseRecurrenceUnit:ExpenseRecurrenceUnit.month,
              DateTime:2024-06-01 00:00:00.000Z,        
              'Weekly shop',
              'households/home-1/share/expenses/exp-1.jpg',
              null,
              null,
              null,
              null,
              null,
              null,
              null,
              false
            ]
     Which: has length of <16>

  package:matcher                                     expect
  package:flutter_test/src/widget_tester.dart 473:18  expect
  test\contracts\share\models_test.dart 53:7          main.<fn>.<fn>


To run this test again: C:\flutter\bin\cache\dart-sdk\bin\dart.exe test C:/Users/tomzq/StudioProjects/Kinly/kinly/test/contracts/share/models_test.dart -p vm --plain-name "TodayShareOwedItem props contains all fields"       
00:29 +338 -3: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/core/di/compose_test.dart: (setUpAll)
supabase.supabase_flutter: INFO: ***** Supabase init completed *****
01:05 +762 -3: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/flow/ui/flow_chore_detail_screen_test.dart: (setUpAll)
supabase.supabase_flutter: INFO: ***** Supabase init completed *****
01:13 +852 -3: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/harmony/harmony_screen_mentions_test.dart: mentions visible only for positive mood and clear on flip
unhandled element <sodipodi:namedview/>; Picture key: Svg loader
unhandled element <defs/>; Picture key: Svg loader      
01:14 +856 -3: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/harmony/harmony_screen_rtl_test.dart: HarmonyScreen RTL renders RTL with localized copy and options
unhandled element <sodipodi:namedview/>; Picture key: Svg loader
unhandled element <defs/>; Picture key: Svg loader      
01:15 +868 -3: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/harmony/harmony_submit_navigation_test.dart: successful submit navigates to Today
unhandled element <sodipodi:namedview/>; Picture key: Svg loader
unhandled element <defs/>; Picture key: Svg loader      
02:03 +1217 -4: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart: submits draft without split when no mode chosen [E]     
  No matching calls. All calls: _MockExpensesRepository.create({homeId: home-1, amountCents: null, description: Draft expense, notes: null, evidencePhotoPath: null, allocationTargetType: null, splitType: null, memberIds: null, customSplits: null, unitIds: null, unitSplits: null, recurrenceEvery: null, recurrenceUnit: null, startDate: 2026-04-11 00:00:00.000})
  (If you called `verify(...).called(0);`, please instead use `verifyNever(...);`.)
  WARNING: Please ensure state instances extend Equatable, override == and hashCode, or implement Comparable.   
  Alternatively, consider using Matchers in the expect of the blocTest rather than concrete state instances.    

  package:bloc_test/src/bloc_test.dart 236:7  testBloc  


To run this test again: C:\flutter\bin\cache\dart-sdk\bin\dart.exe test C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart -p vm --plain-name "submits draft without split when no mode chosen"
02:03 +1217 -5: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart: sets validation flag when inputs missing [E]
  Expected: [
              ShareCreateState:ShareCreateState(ShareCreateForm(, , , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, null, null, 0, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)
            ]
    Actual: [
              ShareCreateState:ShareCreateState(ShareCreateForm(, , , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, ExpenseErrorCode.invalidDescription, , 1, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)
            ]
     Which: at location [0] is ShareCreateState:<ShareCreateState(ShareCreateForm(, , , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, ExpenseErrorCode.invalidDescription, , 1, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)> instead of ShareCreateState:<ShareCreateState(ShareCreateForm(, , , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, null, null, 0, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)>

  ==== diff ========================================    

  [ShareCreateState(ShareCreateForm(, , , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, {+Expe+}n[-u-]{+seErrorCode.inva+}l[-l-]{+idDescription+}, [-null-], [-0-]{+1+}, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)]  

  ==== end diff ====================================    

  package:bloc_test/src/bloc_test.dart 226:11  testBloc.<fn>
  ===== asynchronous gap ===========================    
  dart:async                                   _Completer.completeError
  package:bloc_test/src/bloc_test.dart 257:43  _runZonedGuarded.<fn>
  ===== asynchronous gap ===========================    
  dart:async                                   _CustomZone.registerBinaryCallback
  package:bloc_test/src/bloc_test.dart 254:5   _runZonedGuarded.<fn>
  dart:async                                   runZonedGuarded
  package:bloc_test/src/bloc_test.dart 253:3   _runZonedGuarded
  package:bloc_test/src/bloc_test.dart 200:11  testBloc 
  package:bloc_test/src/bloc_test.dart 156:13  blocTest.<fn>


To run this test again: C:\flutter\bin\cache\dart-sdk\bin\dart.exe test C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart -p vm --plain-name "sets validation flag when inputs missing"
02:03 +1217 -6: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart: create mode still requires amount when split mode is set
 [E]
  Expected: [
              ShareCreateState:ShareCreateState(ShareCreateForm(New bill, , , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.equal, [member_a, member_b], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, null, null, 0, null, 0, 0, null, false, null, null, null, true, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)
            ]
    Actual: [
              ShareCreateState:ShareCreateState(ShareCreateForm(New bill, , , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.equal, [member_a, member_b], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, ExpenseErrorCode.invalidAmount, , 1, null, 0, 0, null, false, null, null, null, true, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)
            ]
     Which: at location [0] is ShareCreateState:<ShareCreateState(ShareCreateForm(New bill, , , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.equal, [member_a, member_b], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, ExpenseErrorCode.invalidAmount, , 1, null, 0, 0, null, false, null, null, null, true, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)> instead of ShareCreateState:<ShareCreateState(ShareCreateForm(New bill, , , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.equal, [member_a, member_b], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, null, null, 0, null, 0, 0, null, false, null, null, null, true, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)>

  ==== diff ========================================    

  [ShareCreateState(ShareCreateForm(New bill, , , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.equal, [member_a, member_b], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, {+Expe+}n[-ul-]{+seErrorCode.inva+}l{+idAmount+}, [-null-], [-0-]{+1+}, null, 0, 0, null, false, null, null, null, true, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)]

  ==== end diff ====================================    

  package:bloc_test/src/bloc_test.dart 226:11  testBloc.<fn>
  ===== asynchronous gap ===========================    
  dart:async                                   _Completer.completeError
  package:bloc_test/src/bloc_test.dart 257:43  _runZonedGuarded.<fn>
  ===== asynchronous gap ===========================    
  dart:async                                   _CustomZone.registerBinaryCallback
  package:bloc_test/src/bloc_test.dart 254:5   _runZonedGuarded.<fn>
  dart:async                                   runZonedGuarded
  package:bloc_test/src/bloc_test.dart 253:3   _runZonedGuarded
  package:bloc_test/src/bloc_test.dart 200:11  testBloc 
  package:bloc_test/src/bloc_test.dart 156:13  blocTest.<fn>


To run this test again: C:\flutter\bin\cache\dart-sdk\bin\dart.exe test C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart -p vm --plain-name "create mode still requires amount when split mode is set"
02:03 +1220 -7: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart: blocks recurrence selection without split mode [E]      
  Expected: [
              ShareCreateState:ShareCreateState(ShareCreateForm(Weekly draft, 10.00, , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], 1, ExpenseRecurrenceUnit.week, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, null, null, 0, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)     
            ]
    Actual: [
              ShareCreateState:ShareCreateState(ShareCreateForm(Weekly draft, 10.00, , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], 1, ExpenseRecurrenceUnit.week, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, ExpenseErrorCode.invalidRecurrence, , 1, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)
            ]
     Which: at location [0] is ShareCreateState:<ShareCreateState(ShareCreateForm(Weekly draft, 10.00, , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], 1, ExpenseRecurrenceUnit.week, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, ExpenseErrorCode.invalidRecurrence, , 1, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)> instead of ShareCreateState:<ShareCreateState(ShareCreateForm(Weekly draft, 10.00, , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], 1, ExpenseRecurrenceUnit.week, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, null, null, 0, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)>

  ==== diff ========================================    

  [ShareCreateState(ShareCreateForm(Weekly draft, 10.00, , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], 1, ExpenseRecurrenceUnit.week, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, {+Expe+}n[-ul-]{+seErrorCode.inva+}l{+idRecurrence+}, [-null-], [-0-]{+1+}, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)]

  ==== end diff ====================================    

  package:bloc_test/src/bloc_test.dart 226:11  testBloc.<fn>
  ===== asynchronous gap ===========================    
  dart:async                                   _Completer.completeError
  package:bloc_test/src/bloc_test.dart 257:43  _runZonedGuarded.<fn>
  ===== asynchronous gap ===========================    
  dart:async                                   _CustomZone.registerBinaryCallback
  package:bloc_test/src/bloc_test.dart 254:5   _runZonedGuarded.<fn>
  dart:async                                   runZonedGuarded
  package:bloc_test/src/bloc_test.dart 253:3   _runZonedGuarded
  package:bloc_test/src/bloc_test.dart 200:11  testBloc 
  package:bloc_test/src/bloc_test.dart 156:13  blocTest.<fn>


To run this test again: C:\flutter\bin\cache\dart-sdk\bin\dart.exe test C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart -p vm --plain-name "blocks recurrence selection without split mode"
02:03 +1223 -8: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart: prevents submitting equal split when only creator is selected [E]
  Expected: [
              ShareCreateState:ShareCreateState(ShareCreateForm(Utilities, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.equal, [member_self], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], member_self, false, false, false, false, true, null, null, null, 0, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)
            ]
    Actual: [
              ShareCreateState:ShareCreateState(ShareCreateForm(Utilities, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.equal, [member_self], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], member_self, false, false, false, false, true, null, ExpenseErrorCode.invalidSplit, , 1, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)
            ]
     Which: at location [0] is ShareCreateState:<ShareCreateState(ShareCreateForm(Utilities, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.equal, [member_self], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], member_self, false, false, false, false, true, null, ExpenseErrorCode.invalidSplit, , 1, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)> instead of ShareCreateState:<ShareCreateState(ShareCreateForm(Utilities, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.equal, [member_self], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], member_self, false, false, false, false, true, null, null, null, 0, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)>  

  ==== diff ========================================    

  [ShareCreateState(ShareCreateForm(Utilities, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.equal, [member_self], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], member_self, false, false, false, false, true, null, {+Expe+}n[-u-]{+seErrorCode.inva+}l{+idSp+}l{+it+}, [-null-], [-0-]{+1+}, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)]

  ==== end diff ====================================    

  package:bloc_test/src/bloc_test.dart 226:11  testBloc.<fn>
  ===== asynchronous gap ===========================    
  dart:async                                   _Completer.completeError
  package:bloc_test/src/bloc_test.dart 257:43  _runZonedGuarded.<fn>
  ===== asynchronous gap ===========================    
  dart:async                                   _CustomZone.registerBinaryCallback
  package:bloc_test/src/bloc_test.dart 254:5   _runZonedGuarded.<fn>
  dart:async                                   runZonedGuarded
  package:bloc_test/src/bloc_test.dart 253:3   _runZonedGuarded
  package:bloc_test/src/bloc_test.dart 200:11  testBloc 
  package:bloc_test/src/bloc_test.dart 156:13  blocTest.<fn>


To run this test again: C:\flutter\bin\cache\dart-sdk\bin\dart.exe test C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart -p vm --plain-name "prevents submitting equal split when only creator is selected"
02:03 +1224 -9: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart: prevents submitting when custom split sum mismatches [E]
  Expected: [
              ShareCreateState:ShareCreateState(ShareCreateForm(Supplies, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.custom, [member_a, member_b], [MapEntry(member_a: 4), MapEntry(member_b: 3)], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, null, null, 0, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)     
            ]
    Actual: [
              ShareCreateState:ShareCreateState(ShareCreateForm(Supplies, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.custom, [member_a, member_b], [MapEntry(member_a: 4), MapEntry(member_b: 3)], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, ExpenseErrorCode.invalidSplitsSum, , 1, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)
            ]
     Which: at location [0] is ShareCreateState:<ShareCreateState(ShareCreateForm(Supplies, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.custom, [member_a, member_b], [MapEntry(member_a: 4), MapEntry(member_b: 3)], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, ExpenseErrorCode.invalidSplitsSum, , 1, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)> instead of ShareCreateState:<ShareCreateState(ShareCreateForm(Supplies, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.custom, [member_a, member_b], [MapEntry(member_a: 4), MapEntry(member_b: 3)], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, null, null, 0, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)>

  ==== diff ========================================    

  [ShareCreateState(ShareCreateForm(Supplies, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.custom, [member_a, member_b], [MapEntry(member_a: 4), MapEntry(member_b: 3)], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, {+Expe+}n[-u-]{+seErrorCode.inva+}l{+idSp+}l{+itsSum+}, [-null-], [-0-]{+1+}, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)]

  ==== end diff ====================================    

  package:bloc_test/src/bloc_test.dart 226:11  testBloc.<fn>
  ===== asynchronous gap ===========================    
  dart:async                                   _Completer.completeError
  package:bloc_test/src/bloc_test.dart 257:43  _runZonedGuarded.<fn>
  ===== asynchronous gap ===========================    
  dart:async                                   _CustomZone.registerBinaryCallback
  package:bloc_test/src/bloc_test.dart 254:5   _runZonedGuarded.<fn>
  dart:async                                   runZonedGuarded
  package:bloc_test/src/bloc_test.dart 253:3   _runZonedGuarded
  package:bloc_test/src/bloc_test.dart 200:11  testBloc 
  package:bloc_test/src/bloc_test.dart 156:13  blocTest.<fn>


To run this test again: C:\flutter\bin\cache\dart-sdk\bin\dart.exe test C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart -p vm --plain-name "prevents submitting when custom split sum mismatches"
02:03 +1224 -10: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart: allows submitting custom split with one non-creator debtor [E]
  No matching calls. All calls: _MockExpensesRepository.create({homeId: home-1, amountCents: 1000, description: Utilities, notes: null, evidencePhotoPath: null, allocationTargetType: ExpenseAllocationTargetType.debtorBased, splitType: ExpenseSplitType.custom, memberIds: null, customSplits: [Instance of 'ExpenseCustomSplitInput'], unitIds: null, unitSplits: null, recurrenceEvery: null, recurrenceUnit: null, startDate: 2026-04-11 00:00:00.000})  
  (If you called `verify(...).called(0);`, please instead use `verifyNever(...);`.)
  WARNING: Please ensure state instances extend Equatable, override == and hashCode, or implement Comparable.   
  Alternatively, consider using Matchers in the expect of the blocTest rather than concrete state instances.    

  package:bloc_test/src/bloc_test.dart 236:7  testBloc  


To run this test again: C:\flutter\bin\cache\dart-sdk\bin\dart.exe test C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart -p vm --plain-name "allows submitting custom split with one non-creator debtor"
02:03 +1224 -11: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart: prevents submitting custom split when only creator is selected [E]
  Expected: [
              ShareCreateState:ShareCreateState(ShareCreateForm(Utilities, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.custom, [member_self], [MapEntry(member_self: 10.00)], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], member_self, false, false, false, false, true, null, null, null, 0, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)
            ]
    Actual: [
              ShareCreateState:ShareCreateState(ShareCreateForm(Utilities, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.custom, [member_self], [MapEntry(member_self: 10.00)], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], member_self, false, false, false, false, true, null, ExpenseErrorCode.invalidSplit, , 1, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)
            ]
     Which: at location [0] is ShareCreateState:<ShareCreateState(ShareCreateForm(Utilities, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.custom, [member_self], [MapEntry(member_self: 10.00)], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], member_self, false, false, false, false, true, null, ExpenseErrorCode.invalidSplit, , 1, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)> instead of ShareCreateState:<ShareCreateState(ShareCreateForm(Utilities, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.custom, [member_self], [MapEntry(member_self: 10.00)], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], member_self, false, false, false, false, true, null, null, null, 0, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)>

  ==== diff ========================================    

  [ShareCreateState(ShareCreateForm(Utilities, 10.00, , ExpenseAllocationTargetType.debtorBased, ShareSplitMode.custom, [member_self], [MapEntry(member_self: 10.00)], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], member_self, false, false, false, false, true, null, {+Expe+}n[-u-]{+seErrorCode.inva+}l{+idSp+}l{+it+}, [-null-], [-0-]{+1+}, null, 0, 0, null, false, null, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)]

  ==== end diff ====================================    

  package:bloc_test/src/bloc_test.dart 226:11  testBloc.<fn>
  ===== asynchronous gap ===========================    
  dart:async                                   _Completer.completeError
  package:bloc_test/src/bloc_test.dart 257:43  _runZonedGuarded.<fn>
  ===== asynchronous gap ===========================    
  dart:async                                   _CustomZone.registerBinaryCallback
  package:bloc_test/src/bloc_test.dart 254:5   _runZonedGuarded.<fn>
  dart:async                                   runZonedGuarded
  package:bloc_test/src/bloc_test.dart 253:3   _runZonedGuarded
  package:bloc_test/src/bloc_test.dart 200:11  testBloc 
  package:bloc_test/src/bloc_test.dart 156:13  blocTest.<fn>


To run this test again: C:\flutter\bin\cache\dart-sdk\bin\dart.exe test C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart -p vm --plain-name "prevents submitting custom split when only creator is selected"
02:03 +1225 -12: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart: requires split selection when editing [E]
  Expected: [
              ShareCreateState:ShareCreateState(ShareCreateForm(Draft expense, 15.00, , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, null, null, 0, null, 0, 0, null, true, expense-draft, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)
            ]
    Actual: [
              ShareCreateState:ShareCreateState(ShareCreateForm(Draft expense, 15.00, , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, ExpenseErrorCode.invalidSplit, , 1, null, 0, 0, null, true, expense-draft, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)
            ]
     Which: at location [0] is ShareCreateState:<ShareCreateState(ShareCreateForm(Draft expense, 15.00, , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, ExpenseErrorCode.invalidSplit, , 1, null, 0, 0, null, true, expense-draft, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)> instead of ShareCreateState:<ShareCreateState(ShareCreateForm(Draft expense, 15.00, , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, null, null, 0, null, 0, 0, null, true, expense-draft, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)>

  ==== diff ========================================    

  [ShareCreateState(ShareCreateForm(Draft expense, 15.00, , ExpenseAllocationTargetType.debtorBased, null, [], [], [], [], null, null, 2026-04-11 00:00:00.000, ), [ShareParticipant(membership_a, member_a, Alex, https://example.com/a.png, false), ShareParticipant(membership_b, member_b, Sam, https://example.com/b.png, false), ShareParticipant(membership_self, member_self, Taylor, https://example.com/me.png, true)], [], null, false, false, false, false, true, null, {+Expe+}n[-u-]{+seErrorCode.inva+}l{+idSp+}l{+it+}, [-null-], [-0-]{+1+}, null, 0, 0, null, true, expense-draft, null, null, false, false, false, false, true, null, null, 0, 0, 0, null, null, null, false, null, 0, false)]

  ==== end diff ====================================    

  package:bloc_test/src/bloc_test.dart 226:11  testBloc.<fn>
  ===== asynchronous gap ===========================    
  dart:async                                   _Completer.completeError
  package:bloc_test/src/bloc_test.dart 257:43  _runZonedGuarded.<fn>
  ===== asynchronous gap ===========================    
  dart:async                                   _CustomZone.registerBinaryCallback
  package:bloc_test/src/bloc_test.dart 254:5   _runZonedGuarded.<fn>
  dart:async                                   runZonedGuarded
  package:bloc_test/src/bloc_test.dart 253:3   _runZonedGuarded
  package:bloc_test/src/bloc_test.dart 200:11  testBloc 
  package:bloc_test/src/bloc_test.dart 156:13  blocTest.<fn>


To run this test again: C:\flutter\bin\cache\dart-sdk\bin\dart.exe test C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart -p vm --plain-name "requires split selection when editing"
02:03 +1229 -13: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart: allows editing description when amount is locked [E]   
  No matching calls. All calls: _MockExpensesRepository.edit({expenseId: expense-paid, amountCents: 3000, description: Paid expense, notes: null, evidencePhotoPath: null, allocationTargetType: null, splitType: null, memberIds: null, customSplits: null, unitIds: null, unitSplits: null, recurrenceEvery: null, recurrenceUnit: null, startDate: null})
  (If you called `verify(...).called(0);`, please instead use `verifyNever(...);`.)
  WARNING: Please ensure state instances extend Equatable, override == and hashCode, or implement Comparable.   
  Alternatively, consider using Matchers in the expect of the blocTest rather than concrete state instances.    

  package:bloc_test/src/bloc_test.dart 236:7  testBloc


To run this test again: C:\flutter\bin\cache\dart-sdk\bin\dart.exe test C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/bloc/share_create_bloc_test.dart -p vm --plain-name "allows editing description when amount is locked"
02:19 +1351 -13: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/ui/share_create_form_view_test.dart: ShareCreateFormView shows localized allocation labels and shared unit name
══╡ EXCEPTION CAUGHT BY FLUTTER TEST FRAMEWORK ╞════════════════════════════════════════════════════
The following TestFailure was thrown running a test:    
Expected: exactly one matching candidate
  Actual: _TextWidgetFinder:<Found 2 widgets with text "Flatmates": [
            Text("Flatmates", dependencies: [DefaultSelectionStyle, DefaultTextStyle, MediaQuery]),
            Text("Flatmates", debugLabel: (englishLike bodyLarge 2021).merge((blackMountainView
bodyLarge).apply), inherit: false, color: Color(alpha: 1.0000, red: 0.1137, green: 0.1059, blue:
0.1255, colorSpace: ColorSpace.sRGB), family: Roboto, size: 16.0, weight: 400, letterSpacing: 0.5,
baseline: alphabetic, height: 1.5x, leadingDistribution: even, decoration: Color(alpha: 1.0000, red:
0.1137, green: 0.1059, blue: 0.1255, colorSpace: ColorSpace.sRGB) TextDecoration.none, dependencies:
[DefaultSelectionStyle, DefaultTextStyle, MediaQuery]), 
          ]>
   Which: is too many

When the exception was thrown, this was the stack:      
#4      main.<anonymous closure>.<anonymous closure> (file:///C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/ui/share_create_form_view_test.dart:532:7)  
<asynchronous suspension>
#5      testWidgets.<anonymous closure>.<anonymous closure> (package:flutter_test/src/widget_tester.dart:192:15)
<asynchronous suspension>
#6      TestWidgetsFlutterBinding._runTestBody (package:flutter_test/src/binding.dart:1059:5)
<asynchronous suspension>
<asynchronous suspension>
(elided one frame from package:stack_trace)

This was caught by the test expectation on the following line:
  file:///C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/ui/share_create_form_view_test.dart line 532
The test description was:
  shows localized allocation labels and shared unit name
════════════════════════════════════════════════════════════════════════════════════════════════════
02:19 +1351 -14: C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/ui/share_create_form_view_test.dart: ShareCreateFormView shows localized allocation labels and shared unit name [E]
  Test failed. See exception logs above.
  The test description was: shows localized allocation labels and shared unit name


To run this test again: C:\flutter\bin\cache\dart-sdk\bin\dart.exe test C:/Users/tomzq/StudioProjects/Kinly/kinly/test/features/share/ui/share_create_form_view_test.dart -p vm --plain-name "ShareCreateFormView shows localized allocation labels and shared unit name"
03:42 +1503 -14: Some tests failed.(
  p_home_id uuid,
  p_exclude_self boolean DEFAULT true
)
RETURNS TABLE (
  membership_id   uuid,
  user_id         uuid,
  username        citext,
  role            text,
  valid_from      timestamptz,
  avatar_url      text,
  can_transfer_to boolean
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    m.id AS membership_id,
    m.user_id,
    p.username,
    m.role,
    m.valid_from,
    a.storage_path AS avatar_url,
    (m.role <> 'owner') AS can_transfer_to
  FROM public.memberships m
  JOIN public.profiles p
    ON p.id = m.user_id
  LEFT JOIN public.avatars a
    ON a.id = p.avatar_id
  WHERE m.home_id = p_home_id
    AND m.is_current = TRUE
    AND (p_exclude_self IS FALSE OR m.user_id <> auth.uid())
  ORDER BY
    CASE WHEN m.role = 'owner' THEN 0 ELSE 1 END,
    p.username;
$$;

