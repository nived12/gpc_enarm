// Controllers are registered by hand — the manifest generator is not wired up, so a
// new controller that is not added here silently never connects.
import { application } from "./application"

import ThemeController from "./theme_controller"
application.register("theme", ThemeController)

import TimerController from "./timer_controller"
application.register("timer", TimerController)

import AutosaveController from "./autosave_controller"
application.register("autosave", AutosaveController)

import AnswerSheetController from "./answer_sheet_controller"
application.register("answer-sheet", AnswerSheetController)

import TopicPickerController from "./topic_picker_controller"
application.register("topic-picker", TopicPickerController)

import TimeZoneController from "./time_zone_controller"
application.register("time-zone", TimeZoneController)

import StreakHeartController from "./streak_heart_controller"
application.register("streak-heart", StreakHeartController)

import LandingCaseController from "./landing_case_controller"
application.register("landing-case", LandingCaseController)

import DismissibleController from "./dismissible_controller"
application.register("dismissible", DismissibleController)

import PushSubscriptionController from "./push_subscription_controller"
application.register("push-subscription", PushSubscriptionController)
