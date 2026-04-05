export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  graphql_public: {
    Tables: {
      [_ in never]: never
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      graphql: {
        Args: {
          extensions?: Json
          operationName?: string
          query?: string
          variables?: Json
        }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
  public: {
    Tables: {
      analytics_events: {
        Row: {
          event_type: string
          home_id: string | null
          id: string
          metadata: Json
          occurred_at: string
          user_id: string
        }
        Insert: {
          event_type: string
          home_id?: string | null
          id?: string
          metadata?: Json
          occurred_at?: string
          user_id: string
        }
        Update: {
          event_type?: string
          home_id?: string | null
          id?: string
          metadata?: Json
          occurred_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "analytics_events_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "analytics_events_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      app_version: {
        Row: {
          id: string
          is_current: boolean
          min_supported_version: string
          notes: string | null
          release_date: string
          version_number: string
        }
        Insert: {
          id?: string
          is_current?: boolean
          min_supported_version: string
          notes?: string | null
          release_date?: string
          version_number: string
        }
        Update: {
          id?: string
          is_current?: boolean
          min_supported_version?: string
          notes?: string | null
          release_date?: string
          version_number?: string
        }
        Relationships: []
      }
      avatars: {
        Row: {
          category: string
          created_at: string
          id: string
          name: string
          storage_path: string
        }
        Insert: {
          category: string
          created_at?: string
          id?: string
          name?: string
          storage_path: string
        }
        Update: {
          category?: string
          created_at?: string
          id?: string
          name?: string
          storage_path?: string
        }
        Relationships: []
      }
      candidate_fit_briefings: {
        Row: {
          briefing_payload: Json
          draft_id: string
          generated_at: string
          id: string
          owner_answers_snapshot: Json
          submission_id: string
        }
        Insert: {
          briefing_payload: Json
          draft_id: string
          generated_at?: string
          id?: string
          owner_answers_snapshot: Json
          submission_id: string
        }
        Update: {
          briefing_payload?: Json
          draft_id?: string
          generated_at?: string
          id?: string
          owner_answers_snapshot?: Json
          submission_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "candidate_fit_briefings_draft_id_fkey"
            columns: ["draft_id"]
            isOneToOne: false
            referencedRelation: "fit_check_drafts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "candidate_fit_briefings_submission_id_fkey"
            columns: ["submission_id"]
            isOneToOne: true
            referencedRelation: "candidate_fit_submissions"
            referencedColumns: ["id"]
          },
        ]
      }
      candidate_fit_submissions: {
        Row: {
          anonymous_session_hash: string
          answers: Json
          display_name: string
          draft_id: string
          id: string
          share_token_id: string
          submitted_at: string
        }
        Insert: {
          anonymous_session_hash: string
          answers: Json
          display_name: string
          draft_id: string
          id?: string
          share_token_id: string
          submitted_at?: string
        }
        Update: {
          anonymous_session_hash?: string
          answers?: Json
          display_name?: string
          draft_id?: string
          id?: string
          share_token_id?: string
          submitted_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "candidate_fit_submissions_draft_id_fkey"
            columns: ["draft_id"]
            isOneToOne: false
            referencedRelation: "fit_check_drafts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "candidate_fit_submissions_share_token_id_fkey"
            columns: ["share_token_id"]
            isOneToOne: false
            referencedRelation: "fit_check_share_tokens"
            referencedColumns: ["id"]
          },
        ]
      }
      chore_events: {
        Row: {
          actor_user_id: string
          chore_id: string
          event_type: Database["public"]["Enums"]["chore_event_type"]
          from_state: Database["public"]["Enums"]["chore_state"] | null
          home_id: string
          id: string
          occurred_at: string
          payload: Json
          to_state: Database["public"]["Enums"]["chore_state"] | null
        }
        Insert: {
          actor_user_id: string
          chore_id: string
          event_type: Database["public"]["Enums"]["chore_event_type"]
          from_state?: Database["public"]["Enums"]["chore_state"] | null
          home_id: string
          id?: string
          occurred_at?: string
          payload?: Json
          to_state?: Database["public"]["Enums"]["chore_state"] | null
        }
        Update: {
          actor_user_id?: string
          chore_id?: string
          event_type?: Database["public"]["Enums"]["chore_event_type"]
          from_state?: Database["public"]["Enums"]["chore_state"] | null
          home_id?: string
          id?: string
          occurred_at?: string
          payload?: Json
          to_state?: Database["public"]["Enums"]["chore_state"] | null
        }
        Relationships: [
          {
            foreignKeyName: "chore_events_actor_user_id_fkey"
            columns: ["actor_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chore_events_chore_id_fkey"
            columns: ["chore_id"]
            isOneToOne: false
            referencedRelation: "chores"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chore_events_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
        ]
      }
      chores: {
        Row: {
          assignee_user_id: string | null
          completed_at: string | null
          created_at: string
          created_by_user_id: string
          expectation_photo_path: string | null
          home_id: string
          how_to_video_url: string | null
          id: string
          name: string
          notes: string | null
          recurrence: Database["public"]["Enums"]["recurrence_interval"]
          recurrence_cursor: string | null
          recurrence_every: number | null
          recurrence_unit: string | null
          start_date: string
          state: Database["public"]["Enums"]["chore_state"]
          updated_at: string
        }
        Insert: {
          assignee_user_id?: string | null
          completed_at?: string | null
          created_at?: string
          created_by_user_id: string
          expectation_photo_path?: string | null
          home_id: string
          how_to_video_url?: string | null
          id?: string
          name: string
          notes?: string | null
          recurrence?: Database["public"]["Enums"]["recurrence_interval"]
          recurrence_cursor?: string | null
          recurrence_every?: number | null
          recurrence_unit?: string | null
          start_date?: string
          state?: Database["public"]["Enums"]["chore_state"]
          updated_at?: string
        }
        Update: {
          assignee_user_id?: string | null
          completed_at?: string | null
          created_at?: string
          created_by_user_id?: string
          expectation_photo_path?: string | null
          home_id?: string
          how_to_video_url?: string | null
          id?: string
          name?: string
          notes?: string | null
          recurrence?: Database["public"]["Enums"]["recurrence_interval"]
          recurrence_cursor?: string | null
          recurrence_every?: number | null
          recurrence_unit?: string | null
          start_date?: string
          state?: Database["public"]["Enums"]["chore_state"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "chores_assignee_user_id_fkey"
            columns: ["assignee_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chores_created_by_user_id_fkey"
            columns: ["created_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "chores_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
        ]
      }
      complaint_ai_providers: {
        Row: {
          active: boolean
          adapter_kind: string
          base_url: string | null
          created_at: string
          provider: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          adapter_kind: string
          base_url?: string | null
          created_at?: string
          provider: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          adapter_kind?: string
          base_url?: string | null
          created_at?: string
          provider?: string
          updated_at?: string
        }
        Relationships: []
      }
      complaint_rewrite_routes: {
        Row: {
          active: boolean
          cache_eligible: boolean
          created_at: string
          execution_mode: string
          lane: string
          max_retries: number
          model: string
          policy_version: string
          priority: number
          prompt_version: string
          provider: string
          rewrite_strength: string
          route_id: string
          surface: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          cache_eligible?: boolean
          created_at?: string
          execution_mode?: string
          lane: string
          max_retries?: number
          model: string
          policy_version?: string
          priority?: number
          prompt_version?: string
          provider: string
          rewrite_strength: string
          route_id?: string
          surface: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          cache_eligible?: boolean
          created_at?: string
          execution_mode?: string
          lane?: string
          max_retries?: number
          model?: string
          policy_version?: string
          priority?: number
          prompt_version?: string
          provider?: string
          rewrite_strength?: string
          route_id?: string
          surface?: string
          updated_at?: string
        }
        Relationships: []
      }
      complaint_rewrite_triggers: {
        Row: {
          attempts: number
          author_user_id: string
          created_at: string
          entry_id: string
          error: string | null
          home_id: string
          last_attempt_at: string | null
          last_error_at: string | null
          note: string | null
          processed_at: string | null
          processing_started_at: string | null
          recipient_user_id: string
          request_id: string | null
          retry_after: string | null
          status: string
          updated_at: string
        }
        Insert: {
          attempts?: number
          author_user_id: string
          created_at?: string
          entry_id: string
          error?: string | null
          home_id: string
          last_attempt_at?: string | null
          last_error_at?: string | null
          note?: string | null
          processed_at?: string | null
          processing_started_at?: string | null
          recipient_user_id: string
          request_id?: string | null
          retry_after?: string | null
          status?: string
          updated_at?: string
        }
        Update: {
          attempts?: number
          author_user_id?: string
          created_at?: string
          entry_id?: string
          error?: string | null
          home_id?: string
          last_attempt_at?: string | null
          last_error_at?: string | null
          note?: string | null
          processed_at?: string | null
          processing_started_at?: string | null
          recipient_user_id?: string
          request_id?: string | null
          retry_after?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "complaint_rewrite_triggers_author_user_id_fkey"
            columns: ["author_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "complaint_rewrite_triggers_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: true
            referencedRelation: "home_mood_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "complaint_rewrite_triggers_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "complaint_rewrite_triggers_recipient_user_id_fkey"
            columns: ["recipient_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      device_tokens: {
        Row: {
          created_at: string
          id: string
          last_seen_at: string
          platform: string | null
          provider: string
          status: string
          token: string
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          last_seen_at?: string
          platform?: string | null
          provider?: string
          status?: string
          token: string
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          id?: string
          last_seen_at?: string
          platform?: string | null
          provider?: string
          status?: string
          token?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "device_tokens_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      expense_plan_debtors: {
        Row: {
          debtor_user_id: string
          plan_id: string
          share_amount_cents: number
        }
        Insert: {
          debtor_user_id: string
          plan_id: string
          share_amount_cents: number
        }
        Update: {
          debtor_user_id?: string
          plan_id?: string
          share_amount_cents?: number
        }
        Relationships: [
          {
            foreignKeyName: "expense_plan_debtors_debtor_user_id_fkey"
            columns: ["debtor_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_plan_debtors_plan_id_fkey"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "expense_plans"
            referencedColumns: ["id"]
          },
        ]
      }
      expense_plan_units: {
        Row: {
          home_id: string
          plan_id: string
          share_amount_cents: number
          unit_id: string
        }
        Insert: {
          home_id: string
          plan_id: string
          share_amount_cents: number
          unit_id: string
        }
        Update: {
          home_id?: string
          plan_id?: string
          share_amount_cents?: number
          unit_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "expense_plan_units_plan_id_fkey"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "expense_plans"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_plan_units_unit_id_fkey"
            columns: ["unit_id"]
            isOneToOne: false
            referencedRelation: "home_units"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fk_expense_plan_units_plan_home"
            columns: ["plan_id", "home_id"]
            isOneToOne: false
            referencedRelation: "expense_plans"
            referencedColumns: ["id", "home_id"]
          },
          {
            foreignKeyName: "fk_expense_plan_units_unit_home"
            columns: ["unit_id", "home_id"]
            isOneToOne: false
            referencedRelation: "home_units"
            referencedColumns: ["id", "home_id"]
          },
        ]
      }
      expense_plans: {
        Row: {
          allocation_target_type: string | null
          amount_cents: number
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          home_id: string
          id: string
          next_cycle_date: string
          notes: string | null
          recurrence_every: number
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string
          split_type: Database["public"]["Enums"]["expense_split_type"]
          start_date: string
          status: Database["public"]["Enums"]["expense_plan_status"]
          terminated_at: string | null
          termination_reason: string | null
          updated_at: string
        }
        Insert: {
          allocation_target_type?: string | null
          amount_cents: number
          created_at?: string
          created_by_user_id: string
          description: string
          evidence_photo_path?: string | null
          home_id: string
          id?: string
          next_cycle_date: string
          notes?: string | null
          recurrence_every: number
          recurrence_interval?:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string
          split_type: Database["public"]["Enums"]["expense_split_type"]
          start_date: string
          status?: Database["public"]["Enums"]["expense_plan_status"]
          terminated_at?: string | null
          termination_reason?: string | null
          updated_at?: string
        }
        Update: {
          allocation_target_type?: string | null
          amount_cents?: number
          created_at?: string
          created_by_user_id?: string
          description?: string
          evidence_photo_path?: string | null
          home_id?: string
          id?: string
          next_cycle_date?: string
          notes?: string | null
          recurrence_every?: number
          recurrence_interval?:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit?: string
          split_type?: Database["public"]["Enums"]["expense_split_type"]
          start_date?: string
          status?: Database["public"]["Enums"]["expense_plan_status"]
          terminated_at?: string | null
          termination_reason?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "expense_plans_created_by_user_id_fkey"
            columns: ["created_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_plans_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
        ]
      }
      expense_splits: {
        Row: {
          amount_cents: number
          debtor_user_id: string
          expense_id: string
          marked_paid_at: string | null
          recipient_viewed_at: string | null
          status: Database["public"]["Enums"]["expense_share_status"]
        }
        Insert: {
          amount_cents: number
          debtor_user_id: string
          expense_id: string
          marked_paid_at?: string | null
          recipient_viewed_at?: string | null
          status?: Database["public"]["Enums"]["expense_share_status"]
        }
        Update: {
          amount_cents?: number
          debtor_user_id?: string
          expense_id?: string
          marked_paid_at?: string | null
          recipient_viewed_at?: string | null
          status?: Database["public"]["Enums"]["expense_share_status"]
        }
        Relationships: [
          {
            foreignKeyName: "expense_splits_debtor_user_id_fkey"
            columns: ["debtor_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_splits_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
        ]
      }
      expense_unit_payment_events: {
        Row: {
          amount_cents: number
          created_at: string
          expense_id: string
          id: string
          payer_user_id: string
          unit_id: string
        }
        Insert: {
          amount_cents: number
          created_at?: string
          expense_id: string
          id?: string
          payer_user_id: string
          unit_id: string
        }
        Update: {
          amount_cents?: number
          created_at?: string
          expense_id?: string
          id?: string
          payer_user_id?: string
          unit_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "expense_unit_payment_events_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_unit_payment_events_payer_user_id_fkey"
            columns: ["payer_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_unit_payment_events_unit_id_fkey"
            columns: ["unit_id"]
            isOneToOne: false
            referencedRelation: "home_units"
            referencedColumns: ["id"]
          },
        ]
      }
      expense_unit_splits: {
        Row: {
          amount_cents: number
          expense_id: string
          fully_paid_at: string | null
          home_id: string
          paid_cents: number
          unit_id: string
        }
        Insert: {
          amount_cents: number
          expense_id: string
          fully_paid_at?: string | null
          home_id: string
          paid_cents?: number
          unit_id: string
        }
        Update: {
          amount_cents?: number
          expense_id?: string
          fully_paid_at?: string | null
          home_id?: string
          paid_cents?: number
          unit_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "expense_unit_splits_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expense_unit_splits_unit_id_fkey"
            columns: ["unit_id"]
            isOneToOne: false
            referencedRelation: "home_units"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fk_expense_unit_splits_expense_home"
            columns: ["expense_id", "home_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id", "home_id"]
          },
          {
            foreignKeyName: "fk_expense_unit_splits_unit_home"
            columns: ["unit_id", "home_id"]
            isOneToOne: false
            referencedRelation: "home_units"
            referencedColumns: ["id", "home_id"]
          },
        ]
      }
      expenses: {
        Row: {
          allocation_target_type: string | null
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          fully_paid_at: string | null
          home_id: string
          id: string
          notes: string | null
          plan_id: string | null
          recurrence_every: number | null
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string | null
          split_type: Database["public"]["Enums"]["expense_split_type"] | null
          start_date: string
          status: Database["public"]["Enums"]["expense_status"]
          updated_at: string
        }
        Insert: {
          allocation_target_type?: string | null
          amount_cents?: number | null
          created_at?: string
          created_by_user_id: string
          description: string
          evidence_photo_path?: string | null
          fully_paid_at?: string | null
          home_id: string
          id?: string
          notes?: string | null
          plan_id?: string | null
          recurrence_every?: number | null
          recurrence_interval?:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit?: string | null
          split_type?: Database["public"]["Enums"]["expense_split_type"] | null
          start_date: string
          status?: Database["public"]["Enums"]["expense_status"]
          updated_at?: string
        }
        Update: {
          allocation_target_type?: string | null
          amount_cents?: number | null
          created_at?: string
          created_by_user_id?: string
          description?: string
          evidence_photo_path?: string | null
          fully_paid_at?: string | null
          home_id?: string
          id?: string
          notes?: string | null
          plan_id?: string | null
          recurrence_every?: number | null
          recurrence_interval?:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit?: string | null
          split_type?: Database["public"]["Enums"]["expense_split_type"] | null
          start_date?: string
          status?: Database["public"]["Enums"]["expense_status"]
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "expenses_created_by_user_id_fkey"
            columns: ["created_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fk_expenses_plan_id_restrict"
            columns: ["plan_id"]
            isOneToOne: false
            referencedRelation: "expense_plans"
            referencedColumns: ["id"]
          },
        ]
      }
      fit_check_drafts: {
        Row: {
          claim_token_hash: string
          claim_token_used_at: string | null
          claimed_at: string | null
          created_at: string
          draft_session_token_hash: string | null
          home_attached_at: string | null
          home_id: string | null
          id: string
          owner_answers: Json
          owner_user_id: string | null
          requested_locale_base: string
          updated_at: string
        }
        Insert: {
          claim_token_hash: string
          claim_token_used_at?: string | null
          claimed_at?: string | null
          created_at?: string
          draft_session_token_hash?: string | null
          home_attached_at?: string | null
          home_id?: string | null
          id?: string
          owner_answers: Json
          owner_user_id?: string | null
          requested_locale_base?: string
          updated_at?: string
        }
        Update: {
          claim_token_hash?: string
          claim_token_used_at?: string | null
          claimed_at?: string | null
          created_at?: string
          draft_session_token_hash?: string | null
          home_attached_at?: string | null
          home_id?: string | null
          id?: string
          owner_answers?: Json
          owner_user_id?: string | null
          requested_locale_base?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "fit_check_drafts_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
        ]
      }
      fit_check_rate_limits: {
        Row: {
          bucket_at: string
          k: string
          n: number
          updated_at: string
        }
        Insert: {
          bucket_at: string
          k: string
          n?: number
          updated_at?: string
        }
        Update: {
          bucket_at?: string
          k?: string
          n?: number
          updated_at?: string
        }
        Relationships: []
      }
      fit_check_share_tokens: {
        Row: {
          created_at: string
          draft_id: string
          expires_at: string
          id: string
          revoked_at: string | null
          status: string
          token_hash: string
        }
        Insert: {
          created_at?: string
          draft_id: string
          expires_at: string
          id?: string
          revoked_at?: string | null
          status?: string
          token_hash: string
        }
        Update: {
          created_at?: string
          draft_id?: string
          expires_at?: string
          id?: string
          revoked_at?: string | null
          status?: string
          token_hash?: string
        }
        Relationships: [
          {
            foreignKeyName: "fit_check_share_tokens_draft_id_fkey"
            columns: ["draft_id"]
            isOneToOne: false
            referencedRelation: "fit_check_drafts"
            referencedColumns: ["id"]
          },
        ]
      }
      fit_check_templates: {
        Row: {
          created_at: string
          locale_base: string
          template_key: string
          template_value: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          locale_base: string
          template_key: string
          template_value: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          locale_base?: string
          template_key?: string
          template_value?: string
          updated_at?: string
        }
        Relationships: []
      }
      gratitude_wall_mentions: {
        Row: {
          created_at: string
          home_id: string
          mentioned_user_id: string
          post_id: string
        }
        Insert: {
          created_at?: string
          home_id: string
          mentioned_user_id: string
          post_id: string
        }
        Update: {
          created_at?: string
          home_id?: string
          mentioned_user_id?: string
          post_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "gratitude_wall_mentions_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gratitude_wall_mentions_mentioned_user_id_fkey"
            columns: ["mentioned_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gratitude_wall_mentions_post_id_fkey"
            columns: ["post_id"]
            isOneToOne: false
            referencedRelation: "gratitude_wall_posts"
            referencedColumns: ["id"]
          },
        ]
      }
      gratitude_wall_personal_items: {
        Row: {
          author_user_id: string
          created_at: string
          home_id: string
          id: string
          message: string | null
          mood: Database["public"]["Enums"]["mood_scale"]
          recipient_user_id: string
          source_entry_id: string
          source_kind: string
          source_post_id: string | null
        }
        Insert: {
          author_user_id: string
          created_at?: string
          home_id: string
          id?: string
          message?: string | null
          mood: Database["public"]["Enums"]["mood_scale"]
          recipient_user_id: string
          source_entry_id: string
          source_kind: string
          source_post_id?: string | null
        }
        Update: {
          author_user_id?: string
          created_at?: string
          home_id?: string
          id?: string
          message?: string | null
          mood?: Database["public"]["Enums"]["mood_scale"]
          recipient_user_id?: string
          source_entry_id?: string
          source_kind?: string
          source_post_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "gratitude_wall_personal_items_author_user_id_fkey"
            columns: ["author_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gratitude_wall_personal_items_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gratitude_wall_personal_items_recipient_user_id_fkey"
            columns: ["recipient_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gratitude_wall_personal_items_source_entry_id_fkey"
            columns: ["source_entry_id"]
            isOneToOne: false
            referencedRelation: "home_mood_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gratitude_wall_personal_items_source_post_id_fkey"
            columns: ["source_post_id"]
            isOneToOne: false
            referencedRelation: "gratitude_wall_posts"
            referencedColumns: ["id"]
          },
        ]
      }
      gratitude_wall_personal_reads: {
        Row: {
          last_read_at: string
          user_id: string
        }
        Insert: {
          last_read_at?: string
          user_id: string
        }
        Update: {
          last_read_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "gratitude_wall_personal_reads_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      gratitude_wall_posts: {
        Row: {
          author_user_id: string
          created_at: string
          home_id: string
          id: string
          message: string | null
          mood: Database["public"]["Enums"]["mood_scale"]
          source_entry_id: string | null
        }
        Insert: {
          author_user_id: string
          created_at?: string
          home_id: string
          id?: string
          message?: string | null
          mood: Database["public"]["Enums"]["mood_scale"]
          source_entry_id?: string | null
        }
        Update: {
          author_user_id?: string
          created_at?: string
          home_id?: string
          id?: string
          message?: string | null
          mood?: Database["public"]["Enums"]["mood_scale"]
          source_entry_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "gratitude_wall_posts_author_user_id_fkey"
            columns: ["author_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gratitude_wall_posts_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gratitude_wall_posts_source_entry_id_fkey"
            columns: ["source_entry_id"]
            isOneToOne: false
            referencedRelation: "home_mood_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      gratitude_wall_reads: {
        Row: {
          home_id: string
          last_read_at: string
          user_id: string
        }
        Insert: {
          home_id: string
          last_read_at?: string
          user_id: string
        }
        Update: {
          home_id?: string
          last_read_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "gratitude_wall_reads_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gratitude_wall_reads_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      home_directory_notes: {
        Row: {
          archived_at: string | null
          created_at: string
          created_by_user_id: string
          details: string | null
          home_id: string
          id: string
          note_type: string
          photo_path: string | null
          reference_url: string | null
          title: string
          updated_at: string
          updated_by_user_id: string
        }
        Insert: {
          archived_at?: string | null
          created_at?: string
          created_by_user_id: string
          details?: string | null
          home_id: string
          id?: string
          note_type?: string
          photo_path?: string | null
          reference_url?: string | null
          title: string
          updated_at?: string
          updated_by_user_id: string
        }
        Update: {
          archived_at?: string | null
          created_at?: string
          created_by_user_id?: string
          details?: string | null
          home_id?: string
          id?: string
          note_type?: string
          photo_path?: string | null
          reference_url?: string | null
          title?: string
          updated_at?: string
          updated_by_user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "home_directory_notes_created_by_user_id_fkey"
            columns: ["created_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "home_directory_notes_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "home_directory_notes_updated_by_user_id_fkey"
            columns: ["updated_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      home_directory_service_reminder_acknowledgements: {
        Row: {
          acknowledged_at: string
          reminder_id: string
          user_id: string
        }
        Insert: {
          acknowledged_at?: string
          reminder_id: string
          user_id: string
        }
        Update: {
          acknowledged_at?: string
          reminder_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "home_directory_service_reminder_acknowledgemen_reminder_id_fkey"
            columns: ["reminder_id"]
            isOneToOne: false
            referencedRelation: "home_directory_service_reminders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "home_directory_service_reminder_acknowledgements_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      home_directory_service_reminders: {
        Row: {
          created_at: string
          dismissed_at: string | null
          dismissed_by_user_id: string | null
          due_at: string
          id: string
          reminder_kind: string
          service_id: string
          status: string
          term_end_date: string
          term_start_date: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          dismissed_at?: string | null
          dismissed_by_user_id?: string | null
          due_at: string
          id?: string
          reminder_kind: string
          service_id: string
          status?: string
          term_end_date: string
          term_start_date: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          dismissed_at?: string | null
          dismissed_by_user_id?: string | null
          due_at?: string
          id?: string
          reminder_kind?: string
          service_id?: string
          status?: string
          term_end_date?: string
          term_start_date?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "home_directory_service_reminders_dismissed_by_user_id_fkey"
            columns: ["dismissed_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "home_directory_service_reminders_service_id_fkey"
            columns: ["service_id"]
            isOneToOne: false
            referencedRelation: "home_directory_services"
            referencedColumns: ["id"]
          },
        ]
      }
      home_directory_services: {
        Row: {
          account_reference: string | null
          archived_at: string | null
          created_at: string
          created_by_user_id: string
          custom_label: string | null
          home_id: string
          id: string
          link_url: string | null
          notes: string | null
          provider_name: string
          renewal_reminder_offset_unit: string | null
          renewal_reminder_offset_value: number | null
          service_type: string
          term_end_date: string | null
          term_start_date: string | null
          updated_at: string
          updated_by_user_id: string
        }
        Insert: {
          account_reference?: string | null
          archived_at?: string | null
          created_at?: string
          created_by_user_id: string
          custom_label?: string | null
          home_id: string
          id?: string
          link_url?: string | null
          notes?: string | null
          provider_name: string
          renewal_reminder_offset_unit?: string | null
          renewal_reminder_offset_value?: number | null
          service_type: string
          term_end_date?: string | null
          term_start_date?: string | null
          updated_at?: string
          updated_by_user_id: string
        }
        Update: {
          account_reference?: string | null
          archived_at?: string | null
          created_at?: string
          created_by_user_id?: string
          custom_label?: string | null
          home_id?: string
          id?: string
          link_url?: string | null
          notes?: string | null
          provider_name?: string
          renewal_reminder_offset_unit?: string | null
          renewal_reminder_offset_value?: number | null
          service_type?: string
          term_end_date?: string | null
          term_start_date?: string | null
          updated_at?: string
          updated_by_user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "home_directory_services_created_by_user_id_fkey"
            columns: ["created_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "home_directory_services_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "home_directory_services_updated_by_user_id_fkey"
            columns: ["updated_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      home_directory_wifi: {
        Row: {
          created_at: string
          created_by_user_id: string
          home_id: string
          id: string
          password: string | null
          ssid: string
          updated_at: string
          updated_by_user_id: string
        }
        Insert: {
          created_at?: string
          created_by_user_id: string
          home_id: string
          id?: string
          password?: string | null
          ssid: string
          updated_at?: string
          updated_by_user_id: string
        }
        Update: {
          created_at?: string
          created_by_user_id?: string
          home_id?: string
          id?: string
          password?: string | null
          ssid?: string
          updated_at?: string
          updated_by_user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "home_directory_wifi_created_by_user_id_fkey"
            columns: ["created_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "home_directory_wifi_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: true
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "home_directory_wifi_updated_by_user_id_fkey"
            columns: ["updated_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      home_entitlements: {
        Row: {
          created_at: string
          expires_at: string | null
          home_id: string
          plan: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          expires_at?: string | null
          home_id: string
          plan?: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          expires_at?: string | null
          home_id?: string
          plan?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "home_entitlements_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: true
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
        ]
      }
      home_mood_entries: {
        Row: {
          comment: string | null
          created_at: string
          gratitude_post_id: string | null
          home_id: string
          id: string
          iso_week: number
          iso_week_year: number
          mood: Database["public"]["Enums"]["mood_scale"]
          user_id: string
        }
        Insert: {
          comment?: string | null
          created_at?: string
          gratitude_post_id?: string | null
          home_id: string
          id?: string
          iso_week: number
          iso_week_year: number
          mood: Database["public"]["Enums"]["mood_scale"]
          user_id: string
        }
        Update: {
          comment?: string | null
          created_at?: string
          gratitude_post_id?: string | null
          home_id?: string
          id?: string
          iso_week?: number
          iso_week_year?: number
          mood?: Database["public"]["Enums"]["mood_scale"]
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "home_mood_entries_gratitude_post_id_fkey"
            columns: ["gratitude_post_id"]
            isOneToOne: false
            referencedRelation: "gratitude_wall_posts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "home_mood_entries_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "home_mood_entries_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      home_mood_feedback_counters: {
        Row: {
          feedback_count: number
          first_feedback_at: string | null
          home_id: string
          last_feedback_at: string | null
          last_nps_at: string | null
          last_nps_feedback_count: number
          last_nps_score: number | null
          nps_required: boolean
          user_id: string
        }
        Insert: {
          feedback_count?: number
          first_feedback_at?: string | null
          home_id: string
          last_feedback_at?: string | null
          last_nps_at?: string | null
          last_nps_feedback_count?: number
          last_nps_score?: number | null
          nps_required?: boolean
          user_id: string
        }
        Update: {
          feedback_count?: number
          first_feedback_at?: string | null
          home_id?: string
          last_feedback_at?: string | null
          last_nps_at?: string | null
          last_nps_feedback_count?: number
          last_nps_score?: number | null
          nps_required?: boolean
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "home_mood_feedback_counters_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "home_mood_feedback_counters_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      home_nps: {
        Row: {
          created_at: string
          home_id: string
          id: string
          nps_feedback_count: number
          score: number
          user_id: string
        }
        Insert: {
          created_at?: string
          home_id: string
          id?: string
          nps_feedback_count: number
          score: number
          user_id: string
        }
        Update: {
          created_at?: string
          home_id?: string
          id?: string
          nps_feedback_count?: number
          score?: number
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "home_nps_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "home_nps_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      home_plan_limits: {
        Row: {
          max_value: number
          metric: Database["public"]["Enums"]["home_usage_metric"]
          plan: string
        }
        Insert: {
          max_value: number
          metric: Database["public"]["Enums"]["home_usage_metric"]
          plan: string
        }
        Update: {
          max_value?: number
          metric?: Database["public"]["Enums"]["home_usage_metric"]
          plan?: string
        }
        Relationships: []
      }
      home_unit_members: {
        Row: {
          created_at: string
          home_id: string
          is_active_shared: boolean
          membership_id: string
          unit_id: string
        }
        Insert: {
          created_at?: string
          home_id: string
          is_active_shared?: boolean
          membership_id: string
          unit_id: string
        }
        Update: {
          created_at?: string
          home_id?: string
          is_active_shared?: boolean
          membership_id?: string
          unit_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fk_home_unit_members_membership"
            columns: ["membership_id", "home_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["id", "home_id"]
          },
          {
            foreignKeyName: "fk_home_unit_members_unit"
            columns: ["unit_id", "home_id"]
            isOneToOne: false
            referencedRelation: "home_units"
            referencedColumns: ["id", "home_id"]
          },
        ]
      }
      home_units: {
        Row: {
          archived_at: string | null
          created_at: string
          created_by_user_id: string | null
          home_id: string
          id: string
          name: string
          personal_membership_id: string | null
          unit_type: string
          updated_at: string
        }
        Insert: {
          archived_at?: string | null
          created_at?: string
          created_by_user_id?: string | null
          home_id: string
          id?: string
          name: string
          personal_membership_id?: string | null
          unit_type: string
          updated_at?: string
        }
        Update: {
          archived_at?: string | null
          created_at?: string
          created_by_user_id?: string | null
          home_id?: string
          id?: string
          name?: string
          personal_membership_id?: string | null
          unit_type?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "home_units_created_by_user_id_fkey"
            columns: ["created_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "home_units_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "home_units_personal_membership_id_fkey"
            columns: ["personal_membership_id"]
            isOneToOne: false
            referencedRelation: "memberships"
            referencedColumns: ["id"]
          },
        ]
      }
      home_usage_counters: {
        Row: {
          active_chores: number
          active_expenses: number
          active_members: number
          chore_photos: number
          expense_photos: number
          home_id: string
          house_directory_note_photos: number
          shopping_item_photos: number
          updated_at: string
        }
        Insert: {
          active_chores?: number
          active_expenses?: number
          active_members?: number
          chore_photos?: number
          expense_photos?: number
          home_id: string
          house_directory_note_photos?: number
          shopping_item_photos?: number
          updated_at?: string
        }
        Update: {
          active_chores?: number
          active_expenses?: number
          active_members?: number
          chore_photos?: number
          expense_photos?: number
          home_id?: string
          house_directory_note_photos?: number
          shopping_item_photos?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "home_usage_counters_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: true
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
        ]
      }
      homes: {
        Row: {
          created_at: string
          deactivated_at: string | null
          id: string
          is_active: boolean
          owner_user_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          deactivated_at?: string | null
          id?: string
          is_active?: boolean
          owner_user_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          deactivated_at?: string | null
          id?: string
          is_active?: boolean
          owner_user_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "homes_owner_user_id_fkey"
            columns: ["owner_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      house_norm_templates: {
        Row: {
          body: Json
          created_at: string
          id: string
          locale_base: string
          template_key: string
          updated_at: string
        }
        Insert: {
          body: Json
          created_at?: string
          id?: string
          locale_base: string
          template_key: string
          updated_at?: string
        }
        Update: {
          body?: Json
          created_at?: string
          id?: string
          locale_base?: string
          template_key?: string
          updated_at?: string
        }
        Relationships: []
      }
      house_norms: {
        Row: {
          generated_at: string
          generated_content: Json
          home_id: string
          home_public_id: string | null
          inputs: Json
          last_edited_at: string | null
          last_edited_by: string | null
          locale_base: string
          published_at: string | null
          published_content: Json | null
          published_version: string | null
          status: string
          template_key: string
          updated_at: string
        }
        Insert: {
          generated_at?: string
          generated_content: Json
          home_id: string
          home_public_id?: string | null
          inputs: Json
          last_edited_at?: string | null
          last_edited_by?: string | null
          locale_base: string
          published_at?: string | null
          published_content?: Json | null
          published_version?: string | null
          status?: string
          template_key: string
          updated_at?: string
        }
        Update: {
          generated_at?: string
          generated_content?: Json
          home_id?: string
          home_public_id?: string | null
          inputs?: Json
          last_edited_at?: string | null
          last_edited_by?: string | null
          locale_base?: string
          published_at?: string | null
          published_content?: Json | null
          published_version?: string | null
          status?: string
          template_key?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "house_norms_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: true
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "house_norms_last_edited_by_fkey"
            columns: ["last_edited_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      house_norms_member_views: {
        Row: {
          home_id: string
          user_id: string
          viewed_at: string
        }
        Insert: {
          home_id: string
          user_id: string
          viewed_at?: string
        }
        Update: {
          home_id?: string
          user_id?: string
          viewed_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "house_norms_member_views_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
        ]
      }
      house_norms_publish_jobs: {
        Row: {
          attempt_count: number
          claimed_at: string | null
          created_at: string
          current_stage: string | null
          dispatch_started_at: string | null
          heartbeat_at: string | null
          home_id: string
          home_public_id: string
          job_id: string
          last_error: string | null
          last_error_at: string | null
          last_error_code: string | null
          last_request_id: string | null
          locale_base: string
          manifest_upload_ms: number | null
          payload: Json
          processed_at: string | null
          processing_started_at: string | null
          public_url_path: string
          published_at: string
          published_version: string
          revalidate_ms: number | null
          snapshot_upload_ms: number | null
          status: string
          template_key: string
          updated_at: string
        }
        Insert: {
          attempt_count?: number
          claimed_at?: string | null
          created_at?: string
          current_stage?: string | null
          dispatch_started_at?: string | null
          heartbeat_at?: string | null
          home_id: string
          home_public_id: string
          job_id?: string
          last_error?: string | null
          last_error_at?: string | null
          last_error_code?: string | null
          last_request_id?: string | null
          locale_base: string
          manifest_upload_ms?: number | null
          payload: Json
          processed_at?: string | null
          processing_started_at?: string | null
          public_url_path: string
          published_at: string
          published_version: string
          revalidate_ms?: number | null
          snapshot_upload_ms?: number | null
          status?: string
          template_key: string
          updated_at?: string
        }
        Update: {
          attempt_count?: number
          claimed_at?: string | null
          created_at?: string
          current_stage?: string | null
          dispatch_started_at?: string | null
          heartbeat_at?: string | null
          home_id?: string
          home_public_id?: string
          job_id?: string
          last_error?: string | null
          last_error_at?: string | null
          last_error_code?: string | null
          last_request_id?: string | null
          locale_base?: string
          manifest_upload_ms?: number | null
          payload?: Json
          processed_at?: string | null
          processing_started_at?: string | null
          public_url_path?: string
          published_at?: string
          published_version?: string
          revalidate_ms?: number | null
          snapshot_upload_ms?: number | null
          status?: string
          template_key?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "house_norms_publish_jobs_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
        ]
      }
      house_norms_revisions: {
        Row: {
          change_summary: string | null
          content: Json
          edited_at: string
          editor_user_id: string
          home_id: string
          id: string
        }
        Insert: {
          change_summary?: string | null
          content: Json
          edited_at?: string
          editor_user_id: string
          home_id: string
          id?: string
        }
        Update: {
          change_summary?: string | null
          content?: Json
          edited_at?: string
          editor_user_id?: string
          home_id?: string
          id?: string
        }
        Relationships: [
          {
            foreignKeyName: "house_norms_revisions_editor_user_id_fkey"
            columns: ["editor_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "house_norms_revisions_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "house_norms"
            referencedColumns: ["home_id"]
          },
        ]
      }
      house_pulse_labels: {
        Row: {
          contract_version: string
          image_key: string
          is_active: boolean
          pulse_state: Database["public"]["Enums"]["house_pulse_state"]
          summary_key: string
          title_key: string
          ui: Json
          updated_at: string
        }
        Insert: {
          contract_version: string
          image_key: string
          is_active?: boolean
          pulse_state: Database["public"]["Enums"]["house_pulse_state"]
          summary_key: string
          title_key: string
          ui?: Json
          updated_at?: string
        }
        Update: {
          contract_version?: string
          image_key?: string
          is_active?: boolean
          pulse_state?: Database["public"]["Enums"]["house_pulse_state"]
          summary_key?: string
          title_key?: string
          ui?: Json
          updated_at?: string
        }
        Relationships: []
      }
      house_pulse_reads: {
        Row: {
          contract_version: string
          home_id: string
          iso_week: number
          iso_week_year: number
          last_seen_computed_at: string
          last_seen_pulse_state: Database["public"]["Enums"]["house_pulse_state"]
          seen_at: string
          user_id: string
        }
        Insert: {
          contract_version?: string
          home_id: string
          iso_week: number
          iso_week_year: number
          last_seen_computed_at: string
          last_seen_pulse_state: Database["public"]["Enums"]["house_pulse_state"]
          seen_at?: string
          user_id: string
        }
        Update: {
          contract_version?: string
          home_id?: string
          iso_week?: number
          iso_week_year?: number
          last_seen_computed_at?: string
          last_seen_pulse_state?: Database["public"]["Enums"]["house_pulse_state"]
          seen_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "house_pulse_reads_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "house_pulse_reads_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      house_pulse_weekly: {
        Row: {
          care_present: boolean
          complexity_present: boolean
          computed_at: string
          contract_version: string
          friction_present: boolean
          home_id: string
          iso_week: number
          iso_week_year: number
          member_count: number
          pulse_state: Database["public"]["Enums"]["house_pulse_state"]
          reflection_count: number
          weather_display: Database["public"]["Enums"]["mood_scale"] | null
        }
        Insert: {
          care_present: boolean
          complexity_present?: boolean
          computed_at?: string
          contract_version?: string
          friction_present: boolean
          home_id: string
          iso_week: number
          iso_week_year: number
          member_count: number
          pulse_state: Database["public"]["Enums"]["house_pulse_state"]
          reflection_count: number
          weather_display?: Database["public"]["Enums"]["mood_scale"] | null
        }
        Update: {
          care_present?: boolean
          complexity_present?: boolean
          computed_at?: string
          contract_version?: string
          friction_present?: boolean
          home_id?: string
          iso_week?: number
          iso_week_year?: number
          member_count?: number
          pulse_state?: Database["public"]["Enums"]["house_pulse_state"]
          reflection_count?: number
          weather_display?: Database["public"]["Enums"]["mood_scale"] | null
        }
        Relationships: [
          {
            foreignKeyName: "house_pulse_weekly_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
        ]
      }
      house_vibe_labels: {
        Row: {
          image_key: string
          is_active: boolean
          label_id: string
          mapping_version: string
          summary_key: string
          title_key: string
          ui: Json
          updated_at: string
        }
        Insert: {
          image_key: string
          is_active?: boolean
          label_id: string
          mapping_version: string
          summary_key: string
          title_key: string
          ui?: Json
          updated_at?: string
        }
        Update: {
          image_key?: string
          is_active?: boolean
          label_id?: string
          mapping_version?: string
          summary_key?: string
          title_key?: string
          ui?: Json
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "house_vibe_labels_mapping_version_fkey"
            columns: ["mapping_version"]
            isOneToOne: false
            referencedRelation: "house_vibe_versions"
            referencedColumns: ["mapping_version"]
          },
        ]
      }
      house_vibe_mapping_effects: {
        Row: {
          axis: string
          created_at: string
          delta: number
          mapping_version: string
          option_index: number
          preference_id: string
          weight: number
        }
        Insert: {
          axis: string
          created_at?: string
          delta: number
          mapping_version: string
          option_index: number
          preference_id: string
          weight: number
        }
        Update: {
          axis?: string
          created_at?: string
          delta?: number
          mapping_version?: string
          option_index?: number
          preference_id?: string
          weight?: number
        }
        Relationships: [
          {
            foreignKeyName: "house_vibe_mapping_effects_mapping_version_fkey"
            columns: ["mapping_version"]
            isOneToOne: false
            referencedRelation: "house_vibe_versions"
            referencedColumns: ["mapping_version"]
          },
          {
            foreignKeyName: "house_vibe_mapping_effects_preference_id_fkey"
            columns: ["preference_id"]
            isOneToOne: false
            referencedRelation: "preference_taxonomy"
            referencedColumns: ["preference_id"]
          },
          {
            foreignKeyName: "house_vibe_mapping_effects_preference_id_fkey"
            columns: ["preference_id"]
            isOneToOne: false
            referencedRelation: "preference_taxonomy_active_defs"
            referencedColumns: ["preference_id"]
          },
        ]
      }
      house_vibe_versions: {
        Row: {
          created_at: string
          mapping_version: string
          min_side_count_large: number
          min_side_count_small: number
          status: string
        }
        Insert: {
          created_at?: string
          mapping_version: string
          min_side_count_large?: number
          min_side_count_small?: number
          status?: string
        }
        Update: {
          created_at?: string
          mapping_version?: string
          min_side_count_large?: number
          min_side_count_small?: number
          status?: string
        }
        Relationships: []
      }
      house_vibes: {
        Row: {
          axes: Json
          computed_at: string
          confidence: number
          coverage_answered: number
          coverage_total: number
          home_id: string
          invalidated_at: string | null
          label_id: string
          mapping_version: string
          out_of_date: boolean
        }
        Insert: {
          axes?: Json
          computed_at?: string
          confidence: number
          coverage_answered: number
          coverage_total: number
          home_id: string
          invalidated_at?: string | null
          label_id: string
          mapping_version: string
          out_of_date?: boolean
        }
        Update: {
          axes?: Json
          computed_at?: string
          confidence?: number
          coverage_answered?: number
          coverage_total?: number
          home_id?: string
          invalidated_at?: string | null
          label_id?: string
          mapping_version?: string
          out_of_date?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "fk_house_vibes_label_version"
            columns: ["mapping_version", "label_id"]
            isOneToOne: false
            referencedRelation: "house_vibe_labels"
            referencedColumns: ["mapping_version", "label_id"]
          },
          {
            foreignKeyName: "house_vibes_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "house_vibes_mapping_version_fkey"
            columns: ["mapping_version"]
            isOneToOne: false
            referencedRelation: "house_vibe_versions"
            referencedColumns: ["mapping_version"]
          },
        ]
      }
      invites: {
        Row: {
          code: string
          created_at: string
          home_id: string
          id: string
          revoked_at: string | null
          used_count: number
        }
        Insert: {
          code: string
          created_at?: string
          home_id: string
          id?: string
          revoked_at?: string | null
          used_count?: number
        }
        Update: {
          code?: string
          created_at?: string
          home_id?: string
          id?: string
          revoked_at?: string | null
          used_count?: number
        }
        Relationships: [
          {
            foreignKeyName: "invites_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
        ]
      }
      leads: {
        Row: {
          country_code: string
          created_at: string
          email: string
          id: string
          source: string
          ui_locale: string
          updated_at: string
        }
        Insert: {
          country_code: string
          created_at?: string
          email: string
          id?: string
          source?: string
          ui_locale: string
          updated_at?: string
        }
        Update: {
          country_code?: string
          created_at?: string
          email?: string
          id?: string
          source?: string
          ui_locale?: string
          updated_at?: string
        }
        Relationships: []
      }
      leads_rate_limits: {
        Row: {
          k: string
          n: number
          updated_at: string
        }
        Insert: {
          k: string
          n?: number
          updated_at?: string
        }
        Update: {
          k?: string
          n?: number
          updated_at?: string
        }
        Relationships: []
      }
      member_cap_join_requests: {
        Row: {
          created_at: string
          home_id: string
          id: string
          joiner_user_id: string
          resolution_notified_at: string | null
          resolved_at: string | null
          resolved_payload: Json | null
          resolved_reason: string | null
        }
        Insert: {
          created_at?: string
          home_id: string
          id?: string
          joiner_user_id: string
          resolution_notified_at?: string | null
          resolved_at?: string | null
          resolved_payload?: Json | null
          resolved_reason?: string | null
        }
        Update: {
          created_at?: string
          home_id?: string
          id?: string
          joiner_user_id?: string
          resolution_notified_at?: string | null
          resolved_at?: string | null
          resolved_payload?: Json | null
          resolved_reason?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "member_cap_join_requests_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_cap_join_requests_joiner_user_id_fkey"
            columns: ["joiner_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      member_directory_bank_accounts: {
        Row: {
          account_holder_name: string
          account_number: string
          created_at: string
          id: string
          updated_at: string
          user_id: string
        }
        Insert: {
          account_holder_name: string
          account_number: string
          created_at?: string
          id?: string
          updated_at?: string
          user_id: string
        }
        Update: {
          account_holder_name?: string
          account_number?: string
          created_at?: string
          id?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "member_directory_bank_accounts_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      member_directory_notes: {
        Row: {
          archived_at: string | null
          contact_name: string | null
          created_at: string
          custom_title: string | null
          details: string | null
          id: string
          label: string | null
          note_type: string
          phone_number: string | null
          photo_path: string | null
          reference_url: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          archived_at?: string | null
          contact_name?: string | null
          created_at?: string
          custom_title?: string | null
          details?: string | null
          id?: string
          label?: string | null
          note_type: string
          phone_number?: string | null
          photo_path?: string | null
          reference_url?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          archived_at?: string | null
          contact_name?: string | null
          created_at?: string
          custom_title?: string | null
          details?: string | null
          id?: string
          label?: string | null
          note_type?: string
          phone_number?: string | null
          photo_path?: string | null
          reference_url?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "member_directory_notes_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      member_directory_nudge_dismissals: {
        Row: {
          dismissed_at: string
          home_id: string
          user_id: string
        }
        Insert: {
          dismissed_at?: string
          home_id: string
          user_id: string
        }
        Update: {
          dismissed_at?: string
          home_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "member_directory_nudge_dismissals_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "member_directory_nudge_dismissals_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      memberships: {
        Row: {
          created_at: string
          home_id: string
          id: string
          is_current: boolean | null
          role: string
          updated_at: string
          user_id: string
          valid_from: string
          valid_to: string | null
          validity: unknown
        }
        Insert: {
          created_at?: string
          home_id: string
          id?: string
          is_current?: boolean | null
          role: string
          updated_at?: string
          user_id: string
          valid_from?: string
          valid_to?: string | null
          validity?: unknown
        }
        Update: {
          created_at?: string
          home_id?: string
          id?: string
          is_current?: boolean | null
          role?: string
          updated_at?: string
          user_id?: string
          valid_from?: string
          valid_to?: string | null
          validity?: unknown
        }
        Relationships: [
          {
            foreignKeyName: "memberships_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "memberships_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      notification_preferences: {
        Row: {
          created_at: string
          last_os_sync_at: string | null
          last_sent_local_date: string | null
          locale: string
          os_permission: string
          preferred_hour: number
          preferred_minute: number
          timezone: string
          updated_at: string
          user_id: string
          wants_daily: boolean
        }
        Insert: {
          created_at?: string
          last_os_sync_at?: string | null
          last_sent_local_date?: string | null
          locale: string
          os_permission?: string
          preferred_hour?: number
          preferred_minute?: number
          timezone: string
          updated_at?: string
          user_id: string
          wants_daily?: boolean
        }
        Update: {
          created_at?: string
          last_os_sync_at?: string | null
          last_sent_local_date?: string | null
          locale?: string
          os_permission?: string
          preferred_hour?: number
          preferred_minute?: number
          timezone?: string
          updated_at?: string
          user_id?: string
          wants_daily?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "notification_preferences_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      notification_sends: {
        Row: {
          created_at: string
          error: string | null
          failed_at: string | null
          id: string
          job_run_id: string | null
          local_date: string
          reserved_at: string | null
          sent_at: string | null
          status: string
          token_id: string | null
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          error?: string | null
          failed_at?: string | null
          id?: string
          job_run_id?: string | null
          local_date: string
          reserved_at?: string | null
          sent_at?: string | null
          status: string
          token_id?: string | null
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          error?: string | null
          failed_at?: string | null
          id?: string
          job_run_id?: string | null
          local_date?: string
          reserved_at?: string | null
          sent_at?: string | null
          status?: string
          token_id?: string | null
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fk_notification_sends_token_id"
            columns: ["token_id"]
            isOneToOne: false
            referencedRelation: "device_tokens"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "notification_sends_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      outreach_event_logs: {
        Row: {
          app_key: string
          client_event_id: string | null
          country: string | null
          created_at: string
          event: string
          id: string
          page_key: string
          session_id: string
          source_id_resolved: string
          store: string
          ui_locale: string | null
          utm_campaign: string
          utm_medium: string
          utm_source: string
        }
        Insert: {
          app_key: string
          client_event_id?: string | null
          country?: string | null
          created_at?: string
          event: string
          id?: string
          page_key: string
          session_id: string
          source_id_resolved?: string
          store?: string
          ui_locale?: string | null
          utm_campaign?: string
          utm_medium?: string
          utm_source?: string
        }
        Update: {
          app_key?: string
          client_event_id?: string | null
          country?: string | null
          created_at?: string
          event?: string
          id?: string
          page_key?: string
          session_id?: string
          source_id_resolved?: string
          store?: string
          ui_locale?: string | null
          utm_campaign?: string
          utm_medium?: string
          utm_source?: string
        }
        Relationships: [
          {
            foreignKeyName: "fk_outreach_event_logs_source_resolved"
            columns: ["source_id_resolved"]
            isOneToOne: false
            referencedRelation: "outreach_sources"
            referencedColumns: ["source_id"]
          },
        ]
      }
      outreach_poll_options: {
        Row: {
          active: boolean
          created_at: string
          id: string
          label: string
          option_key: string
          poll_id: string
          position: number
          updated_at: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          id?: string
          label: string
          option_key: string
          poll_id: string
          position: number
          updated_at?: string
        }
        Update: {
          active?: boolean
          created_at?: string
          id?: string
          label?: string
          option_key?: string
          poll_id?: string
          position?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "outreach_poll_options_poll_id_fkey"
            columns: ["poll_id"]
            isOneToOne: false
            referencedRelation: "outreach_polls"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "outreach_poll_options_poll_id_fkey"
            columns: ["poll_id"]
            isOneToOne: false
            referencedRelation: "outreach_polls_overview_v1"
            referencedColumns: ["id"]
          },
        ]
      }
      outreach_poll_result_messages: {
        Row: {
          active: boolean
          created_at: string
          cta_label: string
          id: string
          option_id: string
          poll_id: string
          primary_message: string
          source_id_resolved: string | null
          updated_at: string
          utm_campaign: string | null
        }
        Insert: {
          active?: boolean
          created_at?: string
          cta_label: string
          id?: string
          option_id: string
          poll_id: string
          primary_message: string
          source_id_resolved?: string | null
          updated_at?: string
          utm_campaign?: string | null
        }
        Update: {
          active?: boolean
          created_at?: string
          cta_label?: string
          id?: string
          option_id?: string
          poll_id?: string
          primary_message?: string
          source_id_resolved?: string | null
          updated_at?: string
          utm_campaign?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fk_outreach_poll_result_messages_poll_option"
            columns: ["poll_id", "option_id"]
            isOneToOne: false
            referencedRelation: "outreach_poll_options"
            referencedColumns: ["poll_id", "id"]
          },
          {
            foreignKeyName: "outreach_poll_result_messages_option_id_fkey"
            columns: ["option_id"]
            isOneToOne: false
            referencedRelation: "outreach_poll_options"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "outreach_poll_result_messages_poll_id_fkey"
            columns: ["poll_id"]
            isOneToOne: false
            referencedRelation: "outreach_polls"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "outreach_poll_result_messages_poll_id_fkey"
            columns: ["poll_id"]
            isOneToOne: false
            referencedRelation: "outreach_polls_overview_v1"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "outreach_poll_result_messages_source_id_resolved_fkey"
            columns: ["source_id_resolved"]
            isOneToOne: false
            referencedRelation: "outreach_sources"
            referencedColumns: ["source_id"]
          },
        ]
      }
      outreach_poll_votes: {
        Row: {
          client_vote_id: string | null
          country: string | null
          created_at: string
          id: string
          option_id: string
          page_key: string
          poll_id: string
          session_id: string
          short_link_id: string
          source_id_resolved: string
          store: string
          ui_locale: string | null
          updated_at: string
          utm_campaign: string
          utm_medium: string
          utm_source: string
        }
        Insert: {
          client_vote_id?: string | null
          country?: string | null
          created_at?: string
          id?: string
          option_id: string
          page_key: string
          poll_id: string
          session_id: string
          short_link_id: string
          source_id_resolved: string
          store: string
          ui_locale?: string | null
          updated_at?: string
          utm_campaign: string
          utm_medium: string
          utm_source: string
        }
        Update: {
          client_vote_id?: string | null
          country?: string | null
          created_at?: string
          id?: string
          option_id?: string
          page_key?: string
          poll_id?: string
          session_id?: string
          short_link_id?: string
          source_id_resolved?: string
          store?: string
          ui_locale?: string | null
          updated_at?: string
          utm_campaign?: string
          utm_medium?: string
          utm_source?: string
        }
        Relationships: [
          {
            foreignKeyName: "fk_outreach_poll_votes_poll_option_membership"
            columns: ["poll_id", "option_id"]
            isOneToOne: false
            referencedRelation: "outreach_poll_options"
            referencedColumns: ["poll_id", "id"]
          },
          {
            foreignKeyName: "outreach_poll_votes_poll_id_fkey"
            columns: ["poll_id"]
            isOneToOne: false
            referencedRelation: "outreach_polls"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "outreach_poll_votes_poll_id_fkey"
            columns: ["poll_id"]
            isOneToOne: false
            referencedRelation: "outreach_polls_overview_v1"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "outreach_poll_votes_short_link_id_fkey"
            columns: ["short_link_id"]
            isOneToOne: false
            referencedRelation: "outreach_short_links"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "outreach_poll_votes_short_link_id_fkey"
            columns: ["short_link_id"]
            isOneToOne: false
            referencedRelation: "outreach_short_links_effective"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "outreach_poll_votes_source_id_resolved_fkey"
            columns: ["source_id_resolved"]
            isOneToOne: false
            referencedRelation: "outreach_sources"
            referencedColumns: ["source_id"]
          },
        ]
      }
      outreach_polls: {
        Row: {
          active: boolean
          app_key: string
          created_at: string
          description: string | null
          id: string
          page_key: string
          question: string
          title: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          app_key: string
          created_at?: string
          description?: string | null
          id?: string
          page_key: string
          question: string
          title: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          app_key?: string
          created_at?: string
          description?: string | null
          id?: string
          page_key?: string
          question?: string
          title?: string
          updated_at?: string
        }
        Relationships: []
      }
      outreach_rate_limits: {
        Row: {
          bucket_start: string
          k: string
          n: number
          updated_at: string
        }
        Insert: {
          bucket_start: string
          k: string
          n: number
          updated_at?: string
        }
        Update: {
          bucket_start?: string
          k?: string
          n?: number
          updated_at?: string
        }
        Relationships: []
      }
      outreach_short_links: {
        Row: {
          active: boolean
          app_key: string
          created_at: string
          created_by: string | null
          destination_fingerprint: string
          expires_at: string | null
          id: string
          page_key: string
          short_code: string
          source_id_resolved: string
          target_path: string
          target_query: Json
          updated_at: string
          utm_campaign: string
          utm_medium: string
          utm_source: string
        }
        Insert: {
          active?: boolean
          app_key?: string
          created_at?: string
          created_by?: string | null
          destination_fingerprint: string
          expires_at?: string | null
          id?: string
          page_key: string
          short_code: string
          source_id_resolved?: string
          target_path: string
          target_query?: Json
          updated_at?: string
          utm_campaign: string
          utm_medium: string
          utm_source: string
        }
        Update: {
          active?: boolean
          app_key?: string
          created_at?: string
          created_by?: string | null
          destination_fingerprint?: string
          expires_at?: string | null
          id?: string
          page_key?: string
          short_code?: string
          source_id_resolved?: string
          target_path?: string
          target_query?: Json
          updated_at?: string
          utm_campaign?: string
          utm_medium?: string
          utm_source?: string
        }
        Relationships: [
          {
            foreignKeyName: "fk_outreach_short_links_source_resolved"
            columns: ["source_id_resolved"]
            isOneToOne: false
            referencedRelation: "outreach_sources"
            referencedColumns: ["source_id"]
          },
        ]
      }
      outreach_source_aliases: {
        Row: {
          active: boolean
          alias: string
          created_at: string
          source_id: string
        }
        Insert: {
          active?: boolean
          alias: string
          created_at?: string
          source_id: string
        }
        Update: {
          active?: boolean
          alias?: string
          created_at?: string
          source_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "outreach_source_aliases_source_id_fkey"
            columns: ["source_id"]
            isOneToOne: false
            referencedRelation: "outreach_sources"
            referencedColumns: ["source_id"]
          },
        ]
      }
      outreach_sources: {
        Row: {
          active: boolean
          created_at: string
          label: string
          source_id: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          label: string
          source_id: string
        }
        Update: {
          active?: boolean
          created_at?: string
          label?: string
          source_id?: string
        }
        Relationships: []
      }
      paywall_events: {
        Row: {
          created_at: string
          event_type: string
          home_id: string | null
          id: string
          source: string | null
          user_id: string | null
        }
        Insert: {
          created_at?: string
          event_type: string
          home_id?: string | null
          id?: string
          source?: string | null
          user_id?: string | null
        }
        Update: {
          created_at?: string
          event_type?: string
          home_id?: string | null
          id?: string
          source?: string | null
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "paywall_events_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "paywall_events_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      preference_report_acknowledgements: {
        Row: {
          acknowledged_at: string
          id: string
          report_id: string
          viewer_user_id: string
        }
        Insert: {
          acknowledged_at?: string
          id?: string
          report_id: string
          viewer_user_id: string
        }
        Update: {
          acknowledged_at?: string
          id?: string
          report_id?: string
          viewer_user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "preference_report_acknowledgements_report_id_fkey"
            columns: ["report_id"]
            isOneToOne: false
            referencedRelation: "preference_reports"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "preference_report_acknowledgements_viewer_user_id_fkey"
            columns: ["viewer_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      preference_report_revisions: {
        Row: {
          change_summary: string | null
          content: Json
          edited_at: string
          editor_user_id: string
          id: string
          report_id: string
        }
        Insert: {
          change_summary?: string | null
          content: Json
          edited_at?: string
          editor_user_id: string
          id?: string
          report_id: string
        }
        Update: {
          change_summary?: string | null
          content?: Json
          edited_at?: string
          editor_user_id?: string
          id?: string
          report_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "preference_report_revisions_editor_user_id_fkey"
            columns: ["editor_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "preference_report_revisions_report_id_fkey"
            columns: ["report_id"]
            isOneToOne: false
            referencedRelation: "preference_reports"
            referencedColumns: ["id"]
          },
        ]
      }
      preference_report_templates: {
        Row: {
          body: Json
          created_at: string
          id: string
          locale: string
          template_key: string
          updated_at: string
        }
        Insert: {
          body: Json
          created_at?: string
          id?: string
          locale: string
          template_key: string
          updated_at?: string
        }
        Update: {
          body?: Json
          created_at?: string
          id?: string
          locale?: string
          template_key?: string
          updated_at?: string
        }
        Relationships: []
      }
      preference_reports: {
        Row: {
          generated_at: string
          generated_content: Json
          id: string
          last_edited_at: string | null
          last_edited_by: string | null
          locale: string
          published_at: string
          published_content: Json
          status: string
          subject_user_id: string
          template_key: string
        }
        Insert: {
          generated_at?: string
          generated_content: Json
          id?: string
          last_edited_at?: string | null
          last_edited_by?: string | null
          locale: string
          published_at?: string
          published_content: Json
          status?: string
          subject_user_id: string
          template_key: string
        }
        Update: {
          generated_at?: string
          generated_content?: Json
          id?: string
          last_edited_at?: string | null
          last_edited_by?: string | null
          locale?: string
          published_at?: string
          published_content?: Json
          status?: string
          subject_user_id?: string
          template_key?: string
        }
        Relationships: [
          {
            foreignKeyName: "preference_reports_last_edited_by_fkey"
            columns: ["last_edited_by"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "preference_reports_subject_user_id_fkey"
            columns: ["subject_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      preference_responses: {
        Row: {
          captured_at: string
          option_index: number
          preference_id: string
          user_id: string
        }
        Insert: {
          captured_at?: string
          option_index: number
          preference_id: string
          user_id: string
        }
        Update: {
          captured_at?: string
          option_index?: number
          preference_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "preference_responses_preference_id_fkey"
            columns: ["preference_id"]
            isOneToOne: false
            referencedRelation: "preference_taxonomy"
            referencedColumns: ["preference_id"]
          },
          {
            foreignKeyName: "preference_responses_preference_id_fkey"
            columns: ["preference_id"]
            isOneToOne: false
            referencedRelation: "preference_taxonomy_active_defs"
            referencedColumns: ["preference_id"]
          },
          {
            foreignKeyName: "preference_responses_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      preference_taxonomy: {
        Row: {
          created_at: string
          is_active: boolean
          preference_id: string
        }
        Insert: {
          created_at?: string
          is_active?: boolean
          preference_id: string
        }
        Update: {
          created_at?: string
          is_active?: boolean
          preference_id?: string
        }
        Relationships: []
      }
      preference_taxonomy_defs: {
        Row: {
          aggregation: string
          created_at: string
          description: string
          domain: string
          label: string
          preference_id: string
          safety_notes: string[]
          updated_at: string
          value_keys: string[]
        }
        Insert: {
          aggregation?: string
          created_at?: string
          description: string
          domain: string
          label?: string
          preference_id: string
          safety_notes?: string[]
          updated_at?: string
          value_keys: string[]
        }
        Update: {
          aggregation?: string
          created_at?: string
          description?: string
          domain?: string
          label?: string
          preference_id?: string
          safety_notes?: string[]
          updated_at?: string
          value_keys?: string[]
        }
        Relationships: [
          {
            foreignKeyName: "preference_taxonomy_defs_preference_id_fkey"
            columns: ["preference_id"]
            isOneToOne: true
            referencedRelation: "preference_taxonomy"
            referencedColumns: ["preference_id"]
          },
          {
            foreignKeyName: "preference_taxonomy_defs_preference_id_fkey"
            columns: ["preference_id"]
            isOneToOne: true
            referencedRelation: "preference_taxonomy_active_defs"
            referencedColumns: ["preference_id"]
          },
        ]
      }
      profiles: {
        Row: {
          avatar_id: string
          created_at: string
          deactivated_at: string | null
          email: string | null
          full_name: string | null
          id: string
          updated_at: string
          username: string
        }
        Insert: {
          avatar_id: string
          created_at?: string
          deactivated_at?: string | null
          email?: string | null
          full_name?: string | null
          id: string
          updated_at?: string
          username: string
        }
        Update: {
          avatar_id?: string
          created_at?: string
          deactivated_at?: string | null
          email?: string | null
          full_name?: string | null
          id?: string
          updated_at?: string
          username?: string
        }
        Relationships: [
          {
            foreignKeyName: "profiles_avatar_id_fkey"
            columns: ["avatar_id"]
            isOneToOne: false
            referencedRelation: "avatars"
            referencedColumns: ["id"]
          },
        ]
      }
      recipient_preference_snapshots: {
        Row: {
          created_at: string
          preference_payload: Json
          recipient_preference_snapshot_id: string
          recipient_user_id: string
          rewrite_request_id: string
        }
        Insert: {
          created_at?: string
          preference_payload: Json
          recipient_preference_snapshot_id?: string
          recipient_user_id: string
          rewrite_request_id: string
        }
        Update: {
          created_at?: string
          preference_payload?: Json
          recipient_preference_snapshot_id?: string
          recipient_user_id?: string
          rewrite_request_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fk_recipient_preference_snapshots_request"
            columns: ["rewrite_request_id"]
            isOneToOne: false
            referencedRelation: "rewrite_requests"
            referencedColumns: ["rewrite_request_id"]
          },
        ]
      }
      recipient_snapshots: {
        Row: {
          created_at: string
          home_id: string
          recipient_snapshot_id: string
          recipient_user_ids: string[]
          rewrite_request_id: string
        }
        Insert: {
          created_at?: string
          home_id: string
          recipient_snapshot_id?: string
          recipient_user_ids: string[]
          rewrite_request_id: string
        }
        Update: {
          created_at?: string
          home_id?: string
          recipient_snapshot_id?: string
          recipient_user_ids?: string[]
          rewrite_request_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fk_recipient_snapshots_request"
            columns: ["rewrite_request_id"]
            isOneToOne: false
            referencedRelation: "rewrite_requests"
            referencedColumns: ["rewrite_request_id"]
          },
        ]
      }
      reserved_usernames: {
        Row: {
          name: string
        }
        Insert: {
          name: string
        }
        Update: {
          name?: string
        }
        Relationships: []
      }
      revenuecat_event_processing: {
        Row: {
          attempts: number
          created_at: string
          environment: string
          idempotency_key: string
          last_error: string | null
          status: Database["public"]["Enums"]["revenuecat_processing_status"]
          updated_at: string
        }
        Insert: {
          attempts?: number
          created_at?: string
          environment: string
          idempotency_key: string
          last_error?: string | null
          status?: Database["public"]["Enums"]["revenuecat_processing_status"]
          updated_at?: string
        }
        Update: {
          attempts?: number
          created_at?: string
          environment?: string
          idempotency_key?: string
          last_error?: string | null
          status?: Database["public"]["Enums"]["revenuecat_processing_status"]
          updated_at?: string
        }
        Relationships: []
      }
      revenuecat_webhook_events: {
        Row: {
          created_at: string
          current_period_end_at: string | null
          entitlement_id: string | null
          entitlement_ids: string[] | null
          environment: string
          error: string | null
          event_timestamp: string | null
          fatal_error: string | null
          fatal_error_code: string | null
          home_id: string | null
          id: string
          idempotency_key: string
          last_purchase_at: string | null
          latest_transaction_id: string | null
          original_purchase_at: string | null
          original_transaction_id: string | null
          product_id: string | null
          raw: Json | null
          rc_app_user_id: string
          rc_event_id: string | null
          rpc_error: string | null
          rpc_error_code: string | null
          rpc_retryable: boolean | null
          status: Database["public"]["Enums"]["subscription_status"] | null
          store: Database["public"]["Enums"]["subscription_store"] | null
          warnings: string[] | null
        }
        Insert: {
          created_at?: string
          current_period_end_at?: string | null
          entitlement_id?: string | null
          entitlement_ids?: string[] | null
          environment?: string
          error?: string | null
          event_timestamp?: string | null
          fatal_error?: string | null
          fatal_error_code?: string | null
          home_id?: string | null
          id?: string
          idempotency_key: string
          last_purchase_at?: string | null
          latest_transaction_id?: string | null
          original_purchase_at?: string | null
          original_transaction_id?: string | null
          product_id?: string | null
          raw?: Json | null
          rc_app_user_id: string
          rc_event_id?: string | null
          rpc_error?: string | null
          rpc_error_code?: string | null
          rpc_retryable?: boolean | null
          status?: Database["public"]["Enums"]["subscription_status"] | null
          store?: Database["public"]["Enums"]["subscription_store"] | null
          warnings?: string[] | null
        }
        Update: {
          created_at?: string
          current_period_end_at?: string | null
          entitlement_id?: string | null
          entitlement_ids?: string[] | null
          environment?: string
          error?: string | null
          event_timestamp?: string | null
          fatal_error?: string | null
          fatal_error_code?: string | null
          home_id?: string | null
          id?: string
          idempotency_key?: string
          last_purchase_at?: string | null
          latest_transaction_id?: string | null
          original_purchase_at?: string | null
          original_transaction_id?: string | null
          product_id?: string | null
          raw?: Json | null
          rc_app_user_id?: string
          rc_event_id?: string | null
          rpc_error?: string | null
          rpc_error_code?: string | null
          rpc_retryable?: boolean | null
          status?: Database["public"]["Enums"]["subscription_status"] | null
          store?: Database["public"]["Enums"]["subscription_store"] | null
          warnings?: string[] | null
        }
        Relationships: [
          {
            foreignKeyName: "revenuecat_webhook_events_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
        ]
      }
      rewrite_jobs: {
        Row: {
          attempt_count: number
          claimed_at: string | null
          claimed_by: string | null
          created_at: string
          job_id: string
          lane: string
          language_pair: Json
          last_error: string | null
          last_error_at: string | null
          max_attempts: number
          not_before_at: string | null
          provider_batch_id: string | null
          recipient_preference_snapshot_id: string
          recipient_snapshot_id: string
          recipient_user_id: string
          rewrite_request_id: string
          rewrite_strength: string
          routing_decision: Json
          status: string
          submitted_at: string | null
          surface: string
          task: string
          updated_at: string
        }
        Insert: {
          attempt_count?: number
          claimed_at?: string | null
          claimed_by?: string | null
          created_at?: string
          job_id?: string
          lane: string
          language_pair: Json
          last_error?: string | null
          last_error_at?: string | null
          max_attempts?: number
          not_before_at?: string | null
          provider_batch_id?: string | null
          recipient_preference_snapshot_id: string
          recipient_snapshot_id: string
          recipient_user_id: string
          rewrite_request_id: string
          rewrite_strength: string
          routing_decision: Json
          status?: string
          submitted_at?: string | null
          surface: string
          task: string
          updated_at?: string
        }
        Update: {
          attempt_count?: number
          claimed_at?: string | null
          claimed_by?: string | null
          created_at?: string
          job_id?: string
          lane?: string
          language_pair?: Json
          last_error?: string | null
          last_error_at?: string | null
          max_attempts?: number
          not_before_at?: string | null
          provider_batch_id?: string | null
          recipient_preference_snapshot_id?: string
          recipient_snapshot_id?: string
          recipient_user_id?: string
          rewrite_request_id?: string
          rewrite_strength?: string
          routing_decision?: Json
          status?: string
          submitted_at?: string | null
          surface?: string
          task?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "fk_jobs_pref_snapshot"
            columns: ["recipient_preference_snapshot_id"]
            isOneToOne: false
            referencedRelation: "recipient_preference_snapshots"
            referencedColumns: ["recipient_preference_snapshot_id"]
          },
          {
            foreignKeyName: "fk_jobs_snapshot"
            columns: ["recipient_snapshot_id"]
            isOneToOne: false
            referencedRelation: "recipient_snapshots"
            referencedColumns: ["recipient_snapshot_id"]
          },
          {
            foreignKeyName: "fk_rewrite_jobs_provider_batch"
            columns: ["provider_batch_id"]
            isOneToOne: false
            referencedRelation: "rewrite_provider_batches"
            referencedColumns: ["provider_batch_id"]
          },
          {
            foreignKeyName: "rewrite_jobs_rewrite_request_id_fkey"
            columns: ["rewrite_request_id"]
            isOneToOne: false
            referencedRelation: "rewrite_requests"
            referencedColumns: ["rewrite_request_id"]
          },
        ]
      }
      rewrite_outputs: {
        Row: {
          created_at: string
          eval_result: Json
          lexicon_version: string
          model: string
          output_language: string
          policy_version: string
          prompt_version: string
          provider: string
          recipient_user_id: string
          rewrite_request_id: string
          rewritten_text: string
          target_locale: string
        }
        Insert: {
          created_at?: string
          eval_result: Json
          lexicon_version: string
          model: string
          output_language: string
          policy_version: string
          prompt_version: string
          provider: string
          recipient_user_id: string
          rewrite_request_id: string
          rewritten_text: string
          target_locale: string
        }
        Update: {
          created_at?: string
          eval_result?: Json
          lexicon_version?: string
          model?: string
          output_language?: string
          policy_version?: string
          prompt_version?: string
          provider?: string
          recipient_user_id?: string
          rewrite_request_id?: string
          rewritten_text?: string
          target_locale?: string
        }
        Relationships: [
          {
            foreignKeyName: "rewrite_outputs_rewrite_request_id_fkey"
            columns: ["rewrite_request_id"]
            isOneToOne: false
            referencedRelation: "rewrite_requests"
            referencedColumns: ["rewrite_request_id"]
          },
        ]
      }
      rewrite_provider_batches: {
        Row: {
          created_at: string
          endpoint: string
          error_file_id: string | null
          input_file_id: string | null
          job_count: number
          last_checked_at: string | null
          output_file_id: string | null
          provider: string
          provider_batch_id: string
          status: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          endpoint?: string
          error_file_id?: string | null
          input_file_id?: string | null
          job_count?: number
          last_checked_at?: string | null
          output_file_id?: string | null
          provider: string
          provider_batch_id: string
          status?: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          endpoint?: string
          error_file_id?: string | null
          input_file_id?: string | null
          job_count?: number
          last_checked_at?: string | null
          output_file_id?: string | null
          provider?: string
          provider_batch_id?: string
          status?: string
          updated_at?: string
        }
        Relationships: []
      }
      rewrite_requests: {
        Row: {
          classifier_result: Json
          classifier_version: string
          context_pack: Json
          context_pack_version: string
          created_at: string
          home_id: string
          intent: string
          lane: string
          original_text: string
          policy_version: string
          recipient_preference_snapshot_id: string | null
          recipient_snapshot_id: string | null
          recipient_user_id: string
          rewrite_completed_at: string | null
          rewrite_request: Json
          rewrite_request_id: string
          rewrite_strength: string
          sender_reveal_at: string | null
          sender_user_id: string
          source_locale: string
          status: string
          surface: string
          target_locale: string
          topics: Json
          updated_at: string
        }
        Insert: {
          classifier_result: Json
          classifier_version: string
          context_pack: Json
          context_pack_version: string
          created_at?: string
          home_id: string
          intent: string
          lane: string
          original_text: string
          policy_version: string
          recipient_preference_snapshot_id?: string | null
          recipient_snapshot_id?: string | null
          recipient_user_id: string
          rewrite_completed_at?: string | null
          rewrite_request: Json
          rewrite_request_id: string
          rewrite_strength: string
          sender_reveal_at?: string | null
          sender_user_id: string
          source_locale: string
          status?: string
          surface: string
          target_locale: string
          topics: Json
          updated_at?: string
        }
        Update: {
          classifier_result?: Json
          classifier_version?: string
          context_pack?: Json
          context_pack_version?: string
          created_at?: string
          home_id?: string
          intent?: string
          lane?: string
          original_text?: string
          policy_version?: string
          recipient_preference_snapshot_id?: string | null
          recipient_snapshot_id?: string | null
          recipient_user_id?: string
          rewrite_completed_at?: string | null
          rewrite_request?: Json
          rewrite_request_id?: string
          rewrite_strength?: string
          sender_reveal_at?: string | null
          sender_user_id?: string
          source_locale?: string
          status?: string
          surface?: string
          target_locale?: string
          topics?: Json
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "rewrite_requests_recipient_preference_snapshot_id_fkey"
            columns: ["recipient_preference_snapshot_id"]
            isOneToOne: false
            referencedRelation: "recipient_preference_snapshots"
            referencedColumns: ["recipient_preference_snapshot_id"]
          },
          {
            foreignKeyName: "rewrite_requests_recipient_snapshot_id_fkey"
            columns: ["recipient_snapshot_id"]
            isOneToOne: false
            referencedRelation: "recipient_snapshots"
            referencedColumns: ["recipient_snapshot_id"]
          },
        ]
      }
      share_events: {
        Row: {
          channel: string
          created_at: string
          feature: string
          home_id: string | null
          id: string
          user_id: string
        }
        Insert: {
          channel: string
          created_at?: string
          feature: string
          home_id?: string | null
          id?: string
          user_id: string
        }
        Update: {
          channel?: string
          created_at?: string
          feature?: string
          home_id?: string | null
          id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "share_events_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "share_events_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      shopping_list_items: {
        Row: {
          archived_at: string | null
          archived_by_user_id: string | null
          completed_at: string | null
          completed_by_user_id: string | null
          created_at: string
          created_by_user_id: string
          details: string | null
          home_id: string
          id: string
          is_completed: boolean
          linked_expense_id: string | null
          name: string
          quantity: string | null
          reference_added_by_user_id: string | null
          reference_photo_path: string | null
          scope_type: string
          shopping_list_id: string
          unit_id: string | null
          updated_at: string
        }
        Insert: {
          archived_at?: string | null
          archived_by_user_id?: string | null
          completed_at?: string | null
          completed_by_user_id?: string | null
          created_at?: string
          created_by_user_id: string
          details?: string | null
          home_id: string
          id?: string
          is_completed?: boolean
          linked_expense_id?: string | null
          name: string
          quantity?: string | null
          reference_added_by_user_id?: string | null
          reference_photo_path?: string | null
          scope_type?: string
          shopping_list_id: string
          unit_id?: string | null
          updated_at?: string
        }
        Update: {
          archived_at?: string | null
          archived_by_user_id?: string | null
          completed_at?: string | null
          completed_by_user_id?: string | null
          created_at?: string
          created_by_user_id?: string
          details?: string | null
          home_id?: string
          id?: string
          is_completed?: boolean
          linked_expense_id?: string | null
          name?: string
          quantity?: string | null
          reference_added_by_user_id?: string | null
          reference_photo_path?: string | null
          scope_type?: string
          shopping_list_id?: string
          unit_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "fk_shopping_list_items_list_home"
            columns: ["shopping_list_id", "home_id"]
            isOneToOne: false
            referencedRelation: "shopping_lists"
            referencedColumns: ["id", "home_id"]
          },
          {
            foreignKeyName: "fk_shopping_list_items_unit_home"
            columns: ["unit_id", "home_id"]
            isOneToOne: false
            referencedRelation: "home_units"
            referencedColumns: ["id", "home_id"]
          },
          {
            foreignKeyName: "shopping_list_items_archived_by_user_id_fkey"
            columns: ["archived_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shopping_list_items_completed_by_user_id_fkey"
            columns: ["completed_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shopping_list_items_created_by_user_id_fkey"
            columns: ["created_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shopping_list_items_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shopping_list_items_linked_expense_id_fkey"
            columns: ["linked_expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shopping_list_items_reference_added_by_user_id_fkey"
            columns: ["reference_added_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      shopping_list_purchase_memory: {
        Row: {
          canonical_name: string
          created_at: string
          display_name: string
          home_id: string
          id: string
          last_purchased_at: string
          last_purchased_by_user_id: string
          scope_type: string
          unit_id: string | null
          updated_at: string
          warning_window_days: number
        }
        Insert: {
          canonical_name: string
          created_at?: string
          display_name: string
          home_id: string
          id?: string
          last_purchased_at: string
          last_purchased_by_user_id: string
          scope_type: string
          unit_id?: string | null
          updated_at?: string
          warning_window_days: number
        }
        Update: {
          canonical_name?: string
          created_at?: string
          display_name?: string
          home_id?: string
          id?: string
          last_purchased_at?: string
          last_purchased_by_user_id?: string
          scope_type?: string
          unit_id?: string | null
          updated_at?: string
          warning_window_days?: number
        }
        Relationships: [
          {
            foreignKeyName: "fk_shopping_list_purchase_memory_unit_home"
            columns: ["unit_id", "home_id"]
            isOneToOne: false
            referencedRelation: "home_units"
            referencedColumns: ["id", "home_id"]
          },
          {
            foreignKeyName: "shopping_list_purchase_memory_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
        ]
      }
      shopping_lists: {
        Row: {
          created_at: string
          created_by_user_id: string
          home_id: string
          id: string
          is_active: boolean
          updated_at: string
        }
        Insert: {
          created_at?: string
          created_by_user_id: string
          home_id: string
          id?: string
          is_active?: boolean
          updated_at?: string
        }
        Update: {
          created_at?: string
          created_by_user_id?: string
          home_id?: string
          id?: string
          is_active?: boolean
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "shopping_lists_created_by_user_id_fkey"
            columns: ["created_by_user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shopping_lists_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
        ]
      }
      user_subscriptions: {
        Row: {
          created_at: string
          current_period_end_at: string | null
          home_id: string | null
          id: string
          last_purchase_at: string | null
          last_synced_at: string
          latest_transaction_id: string | null
          original_purchase_at: string | null
          product_id: string
          rc_app_user_id: string
          rc_entitlement_id: string
          status: Database["public"]["Enums"]["subscription_status"]
          store: Database["public"]["Enums"]["subscription_store"]
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          current_period_end_at?: string | null
          home_id?: string | null
          id?: string
          last_purchase_at?: string | null
          last_synced_at?: string
          latest_transaction_id?: string | null
          original_purchase_at?: string | null
          product_id: string
          rc_app_user_id: string
          rc_entitlement_id: string
          status: Database["public"]["Enums"]["subscription_status"]
          store: Database["public"]["Enums"]["subscription_store"]
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          current_period_end_at?: string | null
          home_id?: string | null
          id?: string
          last_purchase_at?: string | null
          last_synced_at?: string
          latest_transaction_id?: string | null
          original_purchase_at?: string | null
          product_id?: string
          rc_app_user_id?: string
          rc_entitlement_id?: string
          status?: Database["public"]["Enums"]["subscription_status"]
          store?: Database["public"]["Enums"]["subscription_store"]
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_subscriptions_home_id_fkey"
            columns: ["home_id"]
            isOneToOne: false
            referencedRelation: "homes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_subscriptions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
            referencedColumns: ["id"]
          },
        ]
      }
      withyou_pack_downloads: {
        Row: {
          app_version: string | null
          country_code: string | null
          id: string
          language: string
          pack_version: string | null
          platform: string | null
          request_path: string | null
          requested_at: string
          user_agent: string | null
        }
        Insert: {
          app_version?: string | null
          country_code?: string | null
          id?: string
          language: string
          pack_version?: string | null
          platform?: string | null
          request_path?: string | null
          requested_at?: string
          user_agent?: string | null
        }
        Update: {
          app_version?: string | null
          country_code?: string | null
          id?: string
          language?: string
          pack_version?: string | null
          platform?: string | null
          request_path?: string | null
          requested_at?: string
          user_agent?: string | null
        }
        Relationships: []
      }
    }
    Views: {
      outreach_poll_results_uc_v1: {
        Row: {
          option_key: string | null
          page_key: string | null
          total_votes: number | null
          vote_count: number | null
        }
        Relationships: []
      }
      outreach_poll_totals_uc_v1: {
        Row: {
          last_vote_at: string | null
          page_key: string | null
          total_votes: number | null
        }
        Relationships: []
      }
      outreach_polls_overview_v1: {
        Row: {
          active: boolean | null
          app_key: string | null
          description: string | null
          id: string | null
          last_activity_at: string | null
          page_key: string | null
          question: string | null
          title: string | null
          total_votes_all: number | null
          total_votes_uc: number | null
        }
        Relationships: []
      }
      outreach_short_links_effective: {
        Row: {
          active: boolean | null
          app_key: string | null
          created_at: string | null
          created_by: string | null
          destination_fingerprint: string | null
          effective_active: boolean | null
          expires_at: string | null
          id: string | null
          page_key: string | null
          short_code: string | null
          source_id_resolved: string | null
          target_path: string | null
          target_query: Json | null
          updated_at: string | null
          utm_campaign: string | null
          utm_medium: string | null
          utm_source: string | null
        }
        Insert: {
          active?: boolean | null
          app_key?: string | null
          created_at?: string | null
          created_by?: string | null
          destination_fingerprint?: string | null
          effective_active?: never
          expires_at?: string | null
          id?: string | null
          page_key?: string | null
          short_code?: string | null
          source_id_resolved?: string | null
          target_path?: string | null
          target_query?: Json | null
          updated_at?: string | null
          utm_campaign?: string | null
          utm_medium?: string | null
          utm_source?: string | null
        }
        Update: {
          active?: boolean | null
          app_key?: string | null
          created_at?: string | null
          created_by?: string | null
          destination_fingerprint?: string | null
          effective_active?: never
          expires_at?: string | null
          id?: string | null
          page_key?: string | null
          short_code?: string | null
          source_id_resolved?: string | null
          target_path?: string | null
          target_query?: Json | null
          updated_at?: string | null
          utm_campaign?: string | null
          utm_medium?: string | null
          utm_source?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fk_outreach_short_links_source_resolved"
            columns: ["source_id_resolved"]
            isOneToOne: false
            referencedRelation: "outreach_sources"
            referencedColumns: ["source_id"]
          },
        ]
      }
      preference_taxonomy_active_defs: {
        Row: {
          aggregation: string | null
          description: string | null
          domain: string | null
          label: string | null
          preference_id: string | null
          safety_notes: string[] | null
          value_keys: string[] | null
        }
        Relationships: []
      }
    }
    Functions: {
      _assert_active_profile: { Args: never; Returns: undefined }
      _assert_authenticated: { Args: never; Returns: undefined }
      _assert_home_active: { Args: { p_home_id: string }; Returns: undefined }
      _assert_home_member: { Args: { p_home_id: string }; Returns: undefined }
      _assert_home_owner: { Args: { p_home_id: string }; Returns: undefined }
      _chore_recurrence_to_every_unit: {
        Args: {
          p_recurrence: Database["public"]["Enums"]["recurrence_interval"]
        }
        Returns: {
          recurrence_every: number
          recurrence_unit: string
        }[]
      }
      _chores_base_for_home: {
        Args: { p_home_id: string }
        Returns: {
          assignee_avatar_storage_path: string
          assignee_full_name: string
          assignee_user_id: string
          created_at: string
          created_by_user_id: string
          current_due_on: string
          home_id: string
          id: string
          name: string
          state: Database["public"]["Enums"]["chore_state"]
        }[]
      }
      _complaint_topics_valid: { Args: { p: Json }; Returns: boolean }
      _current_user_id: { Args: never; Returns: string }
      _ensure_unique_avatar_for_home: {
        Args: { p_home_id: string; p_user_id: string }
        Returns: string
      }
      _expense_build_debtor_splits: {
        Args: {
          p_amount_cents: number
          p_creator_user_id: string
          p_home_id: string
          p_member_ids?: string[]
          p_split_mode: Database["public"]["Enums"]["expense_split_type"]
          p_splits?: Json
        }
        Returns: {
          amount_cents: number
          debtor_user_id: string
        }[]
      }
      _expense_build_unit_splits: {
        Args: {
          p_amount_cents: number
          p_creator_user_id: string
          p_home_id: string
          p_split_mode: Database["public"]["Enums"]["expense_split_type"]
          p_unit_ids?: string[]
          p_unit_splits?: Json
        }
        Returns: {
          amount_cents: number
          unit_id: string
        }[]
      }
      _expense_finalize_if_fully_paid_v2: {
        Args: { p_expense_id: string }
        Returns: boolean
      }
      _expense_get_editability: {
        Args: { p_expense_id: string; p_user_id: string }
        Returns: Json
      }
      _expense_get_validated_debtor_splits: {
        Args: {
          p_amount_cents: number
          p_creator_user_id: string
          p_home_id: string
          p_member_ids?: string[]
          p_split_mode: Database["public"]["Enums"]["expense_split_type"]
          p_splits?: Json
        }
        Returns: {
          amount_cents: number
          debtor_user_id: string
        }[]
      }
      _expense_get_validated_unit_splits: {
        Args: {
          p_amount_cents: number
          p_creator_user_id: string
          p_home_id: string
          p_split_mode: Database["public"]["Enums"]["expense_split_type"]
          p_unit_ids?: string[]
          p_unit_splits?: Json
        }
        Returns: {
          amount_cents: number
          unit_id: string
        }[]
      }
      _expense_lock_expense_for_update: {
        Args: { p_expense_id: string }
        Returns: {
          allocation_target_type: string | null
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          fully_paid_at: string | null
          home_id: string
          id: string
          notes: string | null
          plan_id: string | null
          recurrence_every: number | null
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string | null
          split_type: Database["public"]["Enums"]["expense_split_type"] | null
          start_date: string
          status: Database["public"]["Enums"]["expense_status"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "expenses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _expense_lock_expense_with_home_active: {
        Args: { p_expense_id: string }
        Returns: {
          allocation_target_type: string | null
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          fully_paid_at: string | null
          home_id: string
          id: string
          notes: string | null
          plan_id: string | null
          recurrence_every: number | null
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string | null
          split_type: Database["public"]["Enums"]["expense_split_type"] | null
          start_date: string
          status: Database["public"]["Enums"]["expense_status"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "expenses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _expense_lock_home_active: {
        Args: { p_home_id: string }
        Returns: {
          created_at: string
          deactivated_at: string | null
          id: string
          is_active: boolean
          owner_user_id: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "homes"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _expense_lock_plan_for_update: {
        Args: { p_plan_id: string }
        Returns: {
          allocation_target_type: string | null
          amount_cents: number
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          home_id: string
          id: string
          next_cycle_date: string
          notes: string | null
          recurrence_every: number
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string
          split_type: Database["public"]["Enums"]["expense_split_type"]
          start_date: string
          status: Database["public"]["Enums"]["expense_plan_status"]
          terminated_at: string | null
          termination_reason: string | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "expense_plans"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _expense_lock_plan_with_home_active: {
        Args: { p_plan_id: string }
        Returns: {
          allocation_target_type: string | null
          amount_cents: number
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          home_id: string
          id: string
          next_cycle_date: string
          notes: string | null
          recurrence_every: number
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string
          split_type: Database["public"]["Enums"]["expense_split_type"]
          start_date: string
          status: Database["public"]["Enums"]["expense_plan_status"]
          terminated_at: string | null
          termination_reason: string | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "expense_plans"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _expense_persist_debtor_splits: {
        Args: {
          p_amount_cents: number
          p_creator_user_id: string
          p_expense_id: string
          p_member_ids?: string[]
          p_split_mode: Database["public"]["Enums"]["expense_split_type"]
          p_splits?: Json
        }
        Returns: undefined
      }
      _expense_persist_plan_debtor_targets: {
        Args: {
          p_amount_cents: number
          p_creator_user_id: string
          p_member_ids?: string[]
          p_plan_id: string
          p_split_mode: Database["public"]["Enums"]["expense_split_type"]
          p_splits?: Json
        }
        Returns: undefined
      }
      _expense_persist_plan_unit_targets: {
        Args: {
          p_amount_cents: number
          p_creator_user_id: string
          p_plan_id: string
          p_split_mode: Database["public"]["Enums"]["expense_split_type"]
          p_unit_ids?: string[]
          p_unit_splits?: Json
        }
        Returns: undefined
      }
      _expense_persist_unit_splits: {
        Args: {
          p_amount_cents: number
          p_creator_user_id: string
          p_expense_id: string
          p_split_mode: Database["public"]["Enums"]["expense_split_type"]
          p_unit_ids?: string[]
          p_unit_splits?: Json
        }
        Returns: undefined
      }
      _expense_plan_generate_cycle: {
        Args: { p_cycle_date: string; p_plan_id: string }
        Returns: {
          allocation_target_type: string | null
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          fully_paid_at: string | null
          home_id: string
          id: string
          notes: string | null
          plan_id: string | null
          recurrence_every: number | null
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string | null
          split_type: Database["public"]["Enums"]["expense_split_type"] | null
          start_date: string
          status: Database["public"]["Enums"]["expense_status"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "expenses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _expense_plan_generate_cycle_v3: {
        Args: {
          p_apply_quota?: boolean
          p_cycle_date: string
          p_plan_id: string
        }
        Returns: {
          allocation_target_type: string | null
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          fully_paid_at: string | null
          home_id: string
          id: string
          notes: string | null
          plan_id: string | null
          recurrence_every: number | null
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string | null
          split_type: Database["public"]["Enums"]["expense_split_type"] | null
          start_date: string
          status: Database["public"]["Enums"]["expense_status"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "expenses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _expense_plan_next_cycle_date: {
        Args: {
          p_from: string
          p_interval: Database["public"]["Enums"]["recurrence_interval"]
        }
        Returns: string
      }
      _expense_plan_next_cycle_date_v2: {
        Args: { p_every: number; p_from: string; p_unit: string }
        Returns: string
      }
      _expense_plans_terminate_for_member_change: {
        Args: { p_affected_user_id: string; p_home_id: string }
        Returns: undefined
      }
      _expense_quota_apply_activate_one_off: {
        Args: { p_home_id: string; p_photo_delta?: number }
        Returns: undefined
      }
      _expense_quota_apply_activate_plan_with_first_cycle: {
        Args: { p_home_id: string; p_photo_delta?: number }
        Returns: undefined
      }
      _expense_quota_apply_finalize_expense: {
        Args: { p_home_id: string }
        Returns: undefined
      }
      _expense_quota_apply_generate_cycle: {
        Args: { p_home_id: string }
        Returns: undefined
      }
      _expense_quota_assert_activate_one_off: {
        Args: { p_home_id: string; p_photo_delta?: number }
        Returns: undefined
      }
      _expense_quota_assert_activate_plan_with_first_cycle: {
        Args: { p_home_id: string; p_photo_delta?: number }
        Returns: undefined
      }
      _expense_quota_assert_generate_cycle: {
        Args: { p_home_id: string }
        Returns: undefined
      }
      _expense_require_current_membership: {
        Args: { p_home_id: string; p_user_id: string }
        Returns: {
          created_at: string
          home_id: string
          id: string
          is_current: boolean | null
          role: string
          updated_at: string
          user_id: string
          valid_from: string
          valid_to: string | null
          validity: unknown
        }
        SetofOptions: {
          from: "*"
          to: "memberships"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _expense_validate_common_fields: {
        Args: {
          p_allow_null_amount: boolean
          p_amount_cents: number
          p_description: string
          p_notes: string
        }
        Returns: undefined
      }
      _expense_validate_evidence_photo_path: {
        Args: { p_evidence_photo_path: string }
        Returns: string
      }
      _expense_validate_photo_transition: {
        Args: { p_new_path: string; p_old_path: string }
        Returns: number
      }
      _expense_validate_recurrence_fields: {
        Args: { p_recurrence_every: number; p_recurrence_unit: string }
        Returns: undefined
      }
      _expense_validate_start_date_range: {
        Args: { p_home_id: string; p_start_date: string; p_user_id: string }
        Returns: undefined
      }
      _expenses_prepare_split_buffer: {
        Args: {
          p_amount_cents: number
          p_creator_id: string
          p_home_id: string
          p_member_ids?: string[]
          p_split_mode: Database["public"]["Enums"]["expense_split_type"]
          p_splits?: Json
        }
        Returns: undefined
      }
      _fit_check_anonymous_session_hash: { Args: never; Returns: string }
      _fit_check_anonymous_session_id: { Args: never; Returns: string }
      _fit_check_assert_owner: {
        Args: { p_draft_id: string }
        Returns: {
          claim_token_hash: string
          claim_token_used_at: string | null
          claimed_at: string | null
          created_at: string
          draft_session_token_hash: string | null
          home_attached_at: string | null
          home_id: string | null
          id: string
          owner_answers: Json
          owner_user_id: string | null
          requested_locale_base: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "fit_check_drafts"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _fit_check_build_continue_in_app_url: {
        Args: { p_claim_token: string }
        Returns: string
      }
      _fit_check_build_share_url: {
        Args: { p_share_token: string }
        Returns: string
      }
      _fit_check_candidate_cta_url: { Args: never; Returns: string }
      _fit_check_claim_token_ttl: { Args: never; Returns: string }
      _fit_check_generate_briefing_payload: {
        Args: { p_candidate_answers: Json; p_owner_answers: Json }
        Returns: Json
      }
      _fit_check_generate_token: { Args: { p_prefix: string }; Returns: string }
      _fit_check_get_active_share_token_for_draft: {
        Args: { p_draft_id: string }
        Returns: {
          created_at: string
          draft_id: string
          expires_at: string
          id: string
          revoked_at: string | null
          status: string
          token_hash: string
        }
        SetofOptions: {
          from: "*"
          to: "fit_check_share_tokens"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _fit_check_get_effective_share_token_by_hash: {
        Args: { p_token_hash: string }
        Returns: {
          created_at: string
          draft_id: string
          expires_at: string
          id: string
          revoked_at: string | null
          status: string
          token_hash: string
        }
        SetofOptions: {
          from: "*"
          to: "fit_check_share_tokens"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _fit_check_onboarding_seed: { Args: { p_answers: Json }; Returns: Json }
      _fit_check_prefill_payload: { Args: { p_answers: Json }; Returns: Json }
      _fit_check_purge_unclaimed_drafts: { Args: never; Returns: number }
      _fit_check_rate_limit_bucketed: {
        Args: { p_bucket: string; p_key: string; p_limit: number }
        Returns: boolean
      }
      _fit_check_reflection_key: { Args: { p_answers: Json }; Returns: string }
      _fit_check_request_headers: { Args: never; Returns: Json }
      _fit_check_requested_locale_base: {
        Args: { p_locale: string }
        Returns: string
      }
      _fit_check_resolved_locale_base: {
        Args: { p_requested_locale_base: string }
        Returns: string
      }
      _fit_check_review_summary_label: {
        Args: { p_briefing_payload: Json; p_requested_locale_base: string }
        Returns: string
      }
      _fit_check_share_token_ttl: { Args: never; Returns: string }
      _fit_check_submission_cap: { Args: never; Returns: number }
      _fit_check_summary_labels: {
        Args: { p_answers: Json; p_requested_locale_base: string }
        Returns: Json
      }
      _fit_check_template_value: {
        Args: { p_requested_locale_base: string; p_template_key: string }
        Returns: string
      }
      _fit_check_unclaimed_purge_ttl: { Args: never; Returns: string }
      _fit_check_validate_answers: { Args: { p_answers: Json }; Returns: Json }
      _gen_invite_code: { Args: never; Returns: string }
      _gen_unique_username: {
        Args: { p_email: string; p_id: string }
        Returns: string
      }
      _home_assert_quota: {
        Args: { p_deltas: Json; p_home_id: string }
        Returns: undefined
      }
      _home_attach_subscription_to_home: {
        Args: { _home_id: string; _user_id: string }
        Returns: undefined
      }
      _home_detach_subscription_to_home: {
        Args: { _home_id: string; _user_id: string }
        Returns: undefined
      }
      _home_effective_plan: { Args: { p_home_id: string }; Returns: string }
      _home_is_premium: { Args: { p_home_id: string }; Returns: boolean }
      _home_units__ensure_personal: {
        Args: { p_home_id: string; p_membership_id: string; p_user_id: string }
        Returns: string
      }
      _home_units__member_user_ids: {
        Args: { p_unit_id: string }
        Returns: string[]
      }
      _home_units__reconcile_member_projection: {
        Args: { p_home_id?: string }
        Returns: number
      }
      _home_units__unit_json: { Args: { p_unit_id: string }; Returns: Json }
      _home_usage_apply_delta: {
        Args: { p_deltas: Json; p_home_id: string }
        Returns: {
          active_chores: number
          active_expenses: number
          active_members: number
          chore_photos: number
          expense_photos: number
          home_id: string
          house_directory_note_photos: number
          shopping_item_photos: number
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "home_usage_counters"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _house_directory_assert_owner: {
        Args: { p_home_id: string }
        Returns: undefined
      }
      _house_directory_assert_valid_reminder_offset: {
        Args: {
          p_offset_unit: string
          p_offset_value: number
          p_term_end_date: string
          p_term_start_date: string
        }
        Returns: undefined
      }
      _house_directory_build_wifi_qr: {
        Args: { p_password: string; p_ssid: string }
        Returns: string
      }
      _house_directory_compute_renewal_due_at: {
        Args: {
          p_offset_unit: string
          p_offset_value: number
          p_term_end_date: string
          p_term_start_date: string
        }
        Returns: string
      }
      _house_directory_due_reminders_json: {
        Args: { p_home_id: string; p_user_id: string }
        Returns: Json
      }
      _house_directory_escape_qr_part: {
        Args: { p_value: string }
        Returns: string
      }
      _house_directory_reconcile_service_reminder: {
        Args: { p_service_id: string }
        Returns: undefined
      }
      _house_directory_today_utc: { Args: never; Returns: string }
      _house_norms_assert_owner: {
        Args: { p_home_id: string }
        Returns: undefined
      }
      _house_norms_build_public_url: {
        Args: { p_home_public_id: string }
        Returns: string
      }
      _house_norms_generate_content: {
        Args: { p_inputs: Json; p_locale_base: string; p_template_body: Json }
        Returns: Json
      }
      _house_norms_generate_public_id: { Args: never; Returns: string }
      _house_norms_inputs_valid: { Args: { p_inputs: Json }; Returns: boolean }
      _house_norms_next_published_version: {
        Args: { p_prev: string }
        Returns: string
      }
      _house_norms_publish_job_dispatch: {
        Args: { p_job_id: string }
        Returns: Json
      }
      _house_norms_publish_sync_call: {
        Args: {
          p_home_public_id: string
          p_locale_base: string
          p_public_url_path?: string
          p_published_at: string
          p_published_content: Json
          p_published_version: string
          p_template_key: string
        }
        Returns: undefined
      }
      _house_norms_section_key_valid: {
        Args: { p_section_key: string }
        Returns: boolean
      }
      _house_norms_text_safe_en: { Args: { p_text: string }; Returns: boolean }
      _house_vibe_confidence_kind: {
        Args: { p_label_id: string }
        Returns: string
      }
      _house_vibes_invalidate: {
        Args: { p_home_id: string }
        Returns: undefined
      }
      _house_vibes_mark_out_of_date: {
        Args: { p_home_id: string }
        Returns: undefined
      }
      _iso_week_utc: {
        Args: { p_at?: string }
        Returns: {
          iso_week: number
          iso_week_year: number
        }[]
      }
      _locale_primary: { Args: { p: string }; Returns: string }
      _member_cap_enqueue_request: {
        Args: { p_home_id: string; p_joiner_user_id: string }
        Returns: {
          created_at: string
          home_id: string
          id: string
          joiner_user_id: string
          resolution_notified_at: string | null
          resolved_at: string | null
          resolved_payload: Json | null
          resolved_reason: string | null
        }
        SetofOptions: {
          from: "*"
          to: "member_cap_join_requests"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _member_cap_resolve_requests: {
        Args: {
          p_home_id: string
          p_payload?: Json
          p_reason: string
          p_request_ids?: string[]
        }
        Returns: undefined
      }
      _member_directory_assert_same_active_home: {
        Args: { p_target_user_id: string }
        Returns: undefined
      }
      _member_directory_assert_valid_photo_path: {
        Args: { p_photo_path: string; p_user_id: string }
        Returns: undefined
      }
      _member_directory_get_current_active_home_id: {
        Args: { p_user_id: string }
        Returns: string
      }
      _outreach_rate_limit_bucketed: {
        Args: { p_bucket_start: string; p_key: string; p_limit: number }
        Returns: boolean
      }
      _outreach_short_links_fingerprint: {
        Args: {
          p_app_key: string
          p_page_key: string
          p_target_path: string
          p_target_query: Json
          p_utm_campaign: string
          p_utm_medium: string
          p_utm_source: string
        }
        Returns: string
      }
      _outreach_short_links_generate_code: {
        Args: { p_len?: number }
        Returns: string
      }
      _outreach_short_links_resolve_source: {
        Args: { p_utm_source: string }
        Returns: string
      }
      _preference_report_to_value_map: {
        Args: { p_report: Json }
        Returns: Json
      }
      _sha256_hex: { Args: { p_input: string }; Returns: string }
      _share_log_event_internal: {
        Args: {
          p_channel: string
          p_feature: string
          p_home_id: string
          p_user_id: string
        }
        Returns: undefined
      }
      _shopping_list__add_item_core: {
        Args: {
          p_details: string
          p_home_id: string
          p_name: string
          p_quantity: string
          p_reference_photo_path: string
          p_scope_type: string
          p_unit_id: string
        }
        Returns: {
          archived_at: string | null
          archived_by_user_id: string | null
          completed_at: string | null
          completed_by_user_id: string | null
          created_at: string
          created_by_user_id: string
          details: string | null
          home_id: string
          id: string
          is_completed: boolean
          linked_expense_id: string | null
          name: string
          quantity: string | null
          reference_added_by_user_id: string | null
          reference_photo_path: string | null
          scope_type: string
          shopping_list_id: string
          unit_id: string | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "shopping_list_items"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _shopping_list__assert_scope_target: {
        Args: { p_home_id: string; p_scope_type: string; p_unit_id: string }
        Returns: {
          scope_type: string
          unit_id: string
        }[]
      }
      _shopping_list__build_add_item_payload: {
        Args: {
          p_item: Database["public"]["Tables"]["shopping_list_items"]["Row"]
        }
        Returns: Json
      }
      _shopping_list__canonicalize_name: {
        Args: { p_name: string }
        Returns: string
      }
      _shopping_list__canonicalize_token: {
        Args: { p_token: string }
        Returns: string
      }
      _shopping_list__get_for_home_core: {
        Args: { p_home_id: string; p_scope_type: string; p_unit_id: string }
        Returns: Json
      }
      _shopping_list__purchase_memory_payload: {
        Args: {
          p_home_id: string
          p_name: string
          p_scope_type: string
          p_unit_id: string
        }
        Returns: Json
      }
      _shopping_list__update_item_core: {
        Args: {
          p_details: string
          p_is_completed: boolean
          p_item_id: string
          p_name: string
          p_quantity: string
          p_reference_photo_path: string
          p_replace_photo: boolean
          p_scope_type: string
          p_unit_id: string
        }
        Returns: {
          archived_at: string | null
          archived_by_user_id: string | null
          completed_at: string | null
          completed_by_user_id: string | null
          created_at: string
          created_by_user_id: string
          details: string | null
          home_id: string
          id: string
          is_completed: boolean
          linked_expense_id: string | null
          name: string
          quantity: string | null
          reference_added_by_user_id: string | null
          reference_photo_path: string | null
          scope_type: string
          shopping_list_id: string
          unit_id: string | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "shopping_list_items"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _shopping_list__warning_window_days: {
        Args: { p_canonical_name: string }
        Returns: number
      }
      _shopping_list__write_purchase_memory: {
        Args: { p_item_ids: string[] }
        Returns: undefined
      }
      _shopping_list_get_or_create_active: {
        Args: { p_home_id: string }
        Returns: {
          created_at: string
          created_by_user_id: string
          home_id: string
          id: string
          is_active: boolean
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "shopping_lists"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _to_iso_utc_ms: { Args: { p_ts: string }; Returns: string }
      acknowledge_home_directory_reminder: {
        Args: { p_home_id: string; p_reminder_id: string }
        Returns: Json
      }
      api_assert: {
        Args: {
          p_code: string
          p_condition: boolean
          p_details?: Json
          p_hint?: string
          p_msg: string
          p_sqlstate?: string
        }
        Returns: undefined
      }
      api_error: {
        Args: {
          p_code: string
          p_details?: Json
          p_hint?: string
          p_msg: string
          p_sqlstate?: string
        }
        Returns: undefined
      }
      archive_home_directory_note: {
        Args: { p_home_id: string; p_note_id: string }
        Returns: Json
      }
      archive_home_directory_service: {
        Args: { p_home_id: string; p_service_id: string }
        Returns: Json
      }
      archive_member_directory_note: {
        Args: { p_note_id: string }
        Returns: Json
      }
      avatars_list_for_home: {
        Args: { p_home_id: string }
        Returns: {
          category: string
          id: string
          storage_path: string
        }[]
      }
      check_app_version: { Args: { client_version: string }; Returns: Json }
      chore_complete: { Args: { _chore_id: string }; Returns: Json }
      chores_cancel: { Args: { p_chore_id: string }; Returns: Json }
      chores_create: {
        Args: {
          p_assignee_user_id?: string
          p_expectation_photo_path?: string
          p_home_id: string
          p_how_to_video_url?: string
          p_name: string
          p_notes?: string
          p_recurrence?: Database["public"]["Enums"]["recurrence_interval"]
          p_start_date?: string
        }
        Returns: {
          assignee_user_id: string | null
          completed_at: string | null
          created_at: string
          created_by_user_id: string
          expectation_photo_path: string | null
          home_id: string
          how_to_video_url: string | null
          id: string
          name: string
          notes: string | null
          recurrence: Database["public"]["Enums"]["recurrence_interval"]
          recurrence_cursor: string | null
          recurrence_every: number | null
          recurrence_unit: string | null
          start_date: string
          state: Database["public"]["Enums"]["chore_state"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "chores"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      chores_create_v2: {
        Args: {
          p_assignee_user_id?: string
          p_expectation_photo_path?: string
          p_home_id: string
          p_how_to_video_url?: string
          p_name: string
          p_notes?: string
          p_recurrence_every?: number
          p_recurrence_unit?: string
          p_start_date?: string
        }
        Returns: {
          assignee_user_id: string | null
          completed_at: string | null
          created_at: string
          created_by_user_id: string
          expectation_photo_path: string | null
          home_id: string
          how_to_video_url: string | null
          id: string
          name: string
          notes: string | null
          recurrence: Database["public"]["Enums"]["recurrence_interval"]
          recurrence_cursor: string | null
          recurrence_every: number | null
          recurrence_unit: string | null
          start_date: string
          state: Database["public"]["Enums"]["chore_state"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "chores"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      chores_get_for_home: {
        Args: { p_chore_id: string; p_home_id: string }
        Returns: Json
      }
      chores_list_for_home: {
        Args: { p_home_id: string }
        Returns: {
          assignee_avatar_storage_path: string
          assignee_full_name: string
          assignee_user_id: string
          home_id: string
          id: string
          name: string
          start_date: string
        }[]
      }
      chores_reassign_on_member_leave: {
        Args: { v_home_id: string; v_user_id: string }
        Returns: undefined
      }
      chores_update: {
        Args: {
          p_assignee_user_id: string
          p_chore_id: string
          p_expectation_photo_path?: string
          p_how_to_video_url?: string
          p_name: string
          p_notes?: string
          p_recurrence?: Database["public"]["Enums"]["recurrence_interval"]
          p_start_date: string
        }
        Returns: {
          assignee_user_id: string | null
          completed_at: string | null
          created_at: string
          created_by_user_id: string
          expectation_photo_path: string | null
          home_id: string
          how_to_video_url: string | null
          id: string
          name: string
          notes: string | null
          recurrence: Database["public"]["Enums"]["recurrence_interval"]
          recurrence_cursor: string | null
          recurrence_every: number | null
          recurrence_unit: string | null
          start_date: string
          state: Database["public"]["Enums"]["chore_state"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "chores"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      chores_update_v2: {
        Args: {
          p_assignee_user_id: string
          p_chore_id: string
          p_expectation_photo_path?: string
          p_how_to_video_url?: string
          p_name: string
          p_notes?: string
          p_recurrence_every?: number
          p_recurrence_unit?: string
          p_start_date?: string
        }
        Returns: {
          assignee_user_id: string | null
          completed_at: string | null
          created_at: string
          created_by_user_id: string
          expectation_photo_path: string | null
          home_id: string
          how_to_video_url: string | null
          id: string
          name: string
          notes: string | null
          recurrence: Database["public"]["Enums"]["recurrence_interval"]
          recurrence_cursor: string | null
          recurrence_every: number | null
          recurrence_unit: string | null
          start_date: string
          state: Database["public"]["Enums"]["chore_state"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "chores"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      claim_rewrite_jobs_by_ids_for_collect_v1: {
        Args: { p_job_ids: string[] }
        Returns: {
          job_id: string
          provider_batch_id: string
          recipient_user_id: string
          rewrite_request_id: string
          routing_decision: Json
        }[]
      }
      claim_rewrite_jobs_for_batch_collect_v1: {
        Args: { p_limit?: number }
        Returns: {
          job_id: string
          provider_batch_id: string
          recipient_user_id: string
          rewrite_request_id: string
          routing_decision: Json
        }[]
      }
      claim_rewrite_jobs_for_batch_submit_v1: {
        Args: { p_limit?: number }
        Returns: {
          job_id: string
          recipient_user_id: string
          rewrite_request_id: string
          routing_decision: Json
        }[]
      }
      complaint_build_recipient_snapshots: {
        Args: {
          p_home_id: string
          p_preference_payload: Json
          p_recipient_user_id: string
          p_rewrite_request_id: string
        }
        Returns: Json
      }
      complaint_context_build: {
        Args: {
          p_power_mode?: string
          p_recipient_preference_snapshot_id: string
          p_recipient_user_id: string
          p_target_language: string
          p_topics: string[]
        }
        Returns: Json
      }
      complaint_fetch_entry_locales: {
        Args: { p_entry_id: string; p_recipient_user_id: string }
        Returns: {
          author_user_id: string
          home_id: string
          original_text: string
          recipient_locale: string
          recipient_user_id: string
        }[]
      }
      complaint_preference_payload: {
        Args: {
          p_recipient_preference_snapshot_id?: string
          p_recipient_user_id: string
        }
        Returns: Json
      }
      complaint_preference_payload_from_responses: {
        Args: { p_recipient_user_id: string }
        Returns: Json
      }
      complaint_rewrite_enqueue: {
        Args: {
          p_classifier_result: Json
          p_classifier_version: string
          p_context_pack: Json
          p_context_pack_version: string
          p_home_id: string
          p_intent: string
          p_lane: string
          p_language_pair: Json
          p_max_attempts?: number
          p_original_text: string
          p_policy_version: string
          p_preference_payload: Json
          p_recipient_user_id: string
          p_rewrite_request: Json
          p_rewrite_request_id: string
          p_rewrite_strength: string
          p_routing_decision: Json
          p_sender_user_id: string
          p_source_locale: string
          p_surface: string
          p_target_locale: string
          p_topics: Json
        }
        Returns: Json
      }
      complaint_rewrite_job_fail_or_requeue: {
        Args: { p_backoff_seconds?: number; p_error: string; p_job_id: string }
        Returns: undefined
      }
      complaint_rewrite_request_exists: {
        Args: { p_rewrite_request_id: string }
        Returns: boolean
      }
      complaint_rewrite_request_fetch_v1: {
        Args: { p_rewrite_request_id: string }
        Returns: {
          policy_version: string
          rewrite_request: Json
          target_locale: string
        }[]
      }
      complaint_rewrite_route: {
        Args: { p_lane: string; p_rewrite_strength: string; p_surface: string }
        Returns: Json
      }
      complaint_trigger_enqueue: {
        Args: { p_entry_id: string; p_recipient_user_id: string }
        Returns: undefined
      }
      complaint_trigger_fail_exhausted: {
        Args: { p_limit?: number; p_max_attempts?: number }
        Returns: number
      }
      complaint_trigger_mark_canceled: {
        Args: {
          p_entry_id: string
          p_processed_at?: string
          p_reason: string
          p_request_id: string
        }
        Returns: boolean
      }
      complaint_trigger_mark_completed: {
        Args: {
          p_entry_id: string
          p_note?: string
          p_processed_at?: string
          p_request_id: string
        }
        Returns: boolean
      }
      complaint_trigger_mark_failed_terminal: {
        Args: {
          p_entry_id: string
          p_error: string
          p_note?: string
          p_processed_at?: string
          p_request_id: string
        }
        Returns: boolean
      }
      complaint_trigger_mark_retry: {
        Args: {
          p_entry_id: string
          p_error: string
          p_note?: string
          p_request_id: string
          p_retry_after: string
        }
        Returns: boolean
      }
      complaint_trigger_pop_pending: {
        Args: { p_limit?: number; p_max_attempts?: number }
        Returns: {
          author_user_id: string
          entry_id: string
          home_id: string
          recipient_user_id: string
          request_id: string
        }[]
      }
      complaint_trigger_requeue_stale_processing: {
        Args: {
          p_limit?: number
          p_retry_delay?: string
          p_stale_after?: string
        }
        Returns: number
      }
      complete_complaint_rewrite_job: {
        Args: {
          p_eval_result: Json
          p_job_id: string
          p_lexicon_version: string
          p_model: string
          p_output_language: string
          p_policy_version: string
          p_prompt_version: string
          p_provider: string
          p_recipient_user_id: string
          p_rewrite_request_id: string
          p_rewritten_text: string
          p_target_locale: string
        }
        Returns: undefined
      }
      create_member_directory_note: {
        Args: {
          p_contact_name?: string
          p_custom_title?: string
          p_details?: string
          p_label?: string
          p_note_type: string
          p_phone_number?: string
          p_photo_path?: string
        }
        Returns: Json
      }
      create_member_directory_note_v2: {
        Args: {
          p_contact_name?: string
          p_custom_title?: string
          p_details?: string
          p_label?: string
          p_note_type: string
          p_phone_number?: string
          p_photo_path?: string
          p_reference_url?: string
        }
        Returns: Json
      }
      dismiss_home_directory_reminder: {
        Args: { p_home_id: string; p_reminder_id: string }
        Returns: Json
      }
      dismiss_member_directory_nudge: { Args: never; Returns: Json }
      expense_plans_generate_due_cycles: { Args: never; Returns: undefined }
      expense_plans_terminate: {
        Args: { p_plan_id: string }
        Returns: {
          allocation_target_type: string | null
          amount_cents: number
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          home_id: string
          id: string
          next_cycle_date: string
          notes: string | null
          recurrence_every: number
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string
          split_type: Database["public"]["Enums"]["expense_split_type"]
          start_date: string
          status: Database["public"]["Enums"]["expense_plan_status"]
          terminated_at: string | null
          termination_reason: string | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "expense_plans"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      expenses_cancel: {
        Args: { p_expense_id: string }
        Returns: {
          allocation_target_type: string | null
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          fully_paid_at: string | null
          home_id: string
          id: string
          notes: string | null
          plan_id: string | null
          recurrence_every: number | null
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string | null
          split_type: Database["public"]["Enums"]["expense_split_type"] | null
          start_date: string
          status: Database["public"]["Enums"]["expense_status"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "expenses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      expenses_create:
        | {
            Args: {
              p_amount_cents?: number
              p_description: string
              p_home_id: string
              p_member_ids?: string[]
              p_notes?: string
              p_split_mode?: Database["public"]["Enums"]["expense_split_type"]
              p_splits?: Json
            }
            Returns: {
              allocation_target_type: string | null
              amount_cents: number | null
              created_at: string
              created_by_user_id: string
              description: string
              evidence_photo_path: string | null
              fully_paid_at: string | null
              home_id: string
              id: string
              notes: string | null
              plan_id: string | null
              recurrence_every: number | null
              recurrence_interval:
                | Database["public"]["Enums"]["recurrence_interval"]
                | null
              recurrence_unit: string | null
              split_type:
                | Database["public"]["Enums"]["expense_split_type"]
                | null
              start_date: string
              status: Database["public"]["Enums"]["expense_status"]
              updated_at: string
            }
            SetofOptions: {
              from: "*"
              to: "expenses"
              isOneToOne: true
              isSetofReturn: false
            }
          }
        | {
            Args: {
              p_amount_cents?: number
              p_description: string
              p_home_id: string
              p_member_ids?: string[]
              p_notes?: string
              p_recurrence?: Database["public"]["Enums"]["recurrence_interval"]
              p_split_mode?: Database["public"]["Enums"]["expense_split_type"]
              p_splits?: Json
              p_start_date?: string
            }
            Returns: {
              allocation_target_type: string | null
              amount_cents: number | null
              created_at: string
              created_by_user_id: string
              description: string
              evidence_photo_path: string | null
              fully_paid_at: string | null
              home_id: string
              id: string
              notes: string | null
              plan_id: string | null
              recurrence_every: number | null
              recurrence_interval:
                | Database["public"]["Enums"]["recurrence_interval"]
                | null
              recurrence_unit: string | null
              split_type:
                | Database["public"]["Enums"]["expense_split_type"]
                | null
              start_date: string
              status: Database["public"]["Enums"]["expense_status"]
              updated_at: string
            }
            SetofOptions: {
              from: "*"
              to: "expenses"
              isOneToOne: true
              isSetofReturn: false
            }
          }
      expenses_create_v2: {
        Args: {
          p_amount_cents?: number
          p_description: string
          p_home_id: string
          p_member_ids?: string[]
          p_notes?: string
          p_recurrence_every?: number
          p_recurrence_unit?: string
          p_split_mode?: Database["public"]["Enums"]["expense_split_type"]
          p_splits?: Json
          p_start_date?: string
        }
        Returns: {
          allocation_target_type: string | null
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          fully_paid_at: string | null
          home_id: string
          id: string
          notes: string | null
          plan_id: string | null
          recurrence_every: number | null
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string | null
          split_type: Database["public"]["Enums"]["expense_split_type"] | null
          start_date: string
          status: Database["public"]["Enums"]["expense_status"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "expenses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      expenses_create_v3: {
        Args: {
          p_amount_cents?: number
          p_description: string
          p_evidence_photo_path?: string
          p_home_id: string
          p_member_ids?: string[]
          p_notes?: string
          p_recurrence_every?: number
          p_recurrence_unit?: string
          p_split_mode?: Database["public"]["Enums"]["expense_split_type"]
          p_splits?: Json
          p_start_date?: string
        }
        Returns: {
          allocation_target_type: string | null
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          fully_paid_at: string | null
          home_id: string
          id: string
          notes: string | null
          plan_id: string | null
          recurrence_every: number | null
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string | null
          split_type: Database["public"]["Enums"]["expense_split_type"] | null
          start_date: string
          status: Database["public"]["Enums"]["expense_status"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "expenses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      expenses_create_v5: {
        Args: {
          p_allocation_target_type?: string
          p_amount_cents?: number
          p_description: string
          p_evidence_photo_path?: string
          p_home_id: string
          p_member_ids?: string[]
          p_notes?: string
          p_recurrence_every?: number
          p_recurrence_unit?: string
          p_split_mode?: Database["public"]["Enums"]["expense_split_type"]
          p_splits?: Json
          p_start_date?: string
          p_unit_ids?: string[]
          p_unit_splits?: Json
        }
        Returns: {
          allocation_target_type: string | null
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          fully_paid_at: string | null
          home_id: string
          id: string
          notes: string | null
          plan_id: string | null
          recurrence_every: number | null
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string | null
          split_type: Database["public"]["Enums"]["expense_split_type"] | null
          start_date: string
          status: Database["public"]["Enums"]["expense_status"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "expenses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      expenses_edit:
        | {
            Args: {
              p_amount_cents: number
              p_description: string
              p_expense_id: string
              p_member_ids?: string[]
              p_notes?: string
              p_split_mode?: Database["public"]["Enums"]["expense_split_type"]
              p_splits?: Json
            }
            Returns: {
              allocation_target_type: string | null
              amount_cents: number | null
              created_at: string
              created_by_user_id: string
              description: string
              evidence_photo_path: string | null
              fully_paid_at: string | null
              home_id: string
              id: string
              notes: string | null
              plan_id: string | null
              recurrence_every: number | null
              recurrence_interval:
                | Database["public"]["Enums"]["recurrence_interval"]
                | null
              recurrence_unit: string | null
              split_type:
                | Database["public"]["Enums"]["expense_split_type"]
                | null
              start_date: string
              status: Database["public"]["Enums"]["expense_status"]
              updated_at: string
            }
            SetofOptions: {
              from: "*"
              to: "expenses"
              isOneToOne: true
              isSetofReturn: false
            }
          }
        | {
            Args: {
              p_amount_cents: number
              p_description: string
              p_expense_id: string
              p_member_ids?: string[]
              p_notes?: string
              p_recurrence?: Database["public"]["Enums"]["recurrence_interval"]
              p_split_mode?: Database["public"]["Enums"]["expense_split_type"]
              p_splits?: Json
              p_start_date?: string
            }
            Returns: {
              allocation_target_type: string | null
              amount_cents: number | null
              created_at: string
              created_by_user_id: string
              description: string
              evidence_photo_path: string | null
              fully_paid_at: string | null
              home_id: string
              id: string
              notes: string | null
              plan_id: string | null
              recurrence_every: number | null
              recurrence_interval:
                | Database["public"]["Enums"]["recurrence_interval"]
                | null
              recurrence_unit: string | null
              split_type:
                | Database["public"]["Enums"]["expense_split_type"]
                | null
              start_date: string
              status: Database["public"]["Enums"]["expense_status"]
              updated_at: string
            }
            SetofOptions: {
              from: "*"
              to: "expenses"
              isOneToOne: true
              isSetofReturn: false
            }
          }
      expenses_edit_v2: {
        Args: {
          p_amount_cents: number
          p_description: string
          p_expense_id: string
          p_member_ids?: string[]
          p_notes?: string
          p_recurrence_every?: number
          p_recurrence_unit?: string
          p_split_mode?: Database["public"]["Enums"]["expense_split_type"]
          p_splits?: Json
          p_start_date?: string
        }
        Returns: {
          allocation_target_type: string | null
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          fully_paid_at: string | null
          home_id: string
          id: string
          notes: string | null
          plan_id: string | null
          recurrence_every: number | null
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string | null
          split_type: Database["public"]["Enums"]["expense_split_type"] | null
          start_date: string
          status: Database["public"]["Enums"]["expense_status"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "expenses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      expenses_edit_v3: {
        Args: {
          p_amount_cents: number
          p_description: string
          p_evidence_photo_path?: string
          p_expense_id: string
          p_member_ids?: string[]
          p_notes?: string
          p_recurrence_every?: number
          p_recurrence_unit?: string
          p_split_mode?: Database["public"]["Enums"]["expense_split_type"]
          p_splits?: Json
          p_start_date?: string
        }
        Returns: {
          allocation_target_type: string | null
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          fully_paid_at: string | null
          home_id: string
          id: string
          notes: string | null
          plan_id: string | null
          recurrence_every: number | null
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string | null
          split_type: Database["public"]["Enums"]["expense_split_type"] | null
          start_date: string
          status: Database["public"]["Enums"]["expense_status"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "expenses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      expenses_edit_v5: {
        Args: {
          p_allocation_target_type?: string
          p_amount_cents: number
          p_description: string
          p_evidence_photo_path?: string
          p_expense_id: string
          p_member_ids?: string[]
          p_notes?: string
          p_recurrence_every?: number
          p_recurrence_unit?: string
          p_split_mode?: Database["public"]["Enums"]["expense_split_type"]
          p_splits?: Json
          p_start_date?: string
          p_unit_ids?: string[]
          p_unit_splits?: Json
        }
        Returns: {
          allocation_target_type: string | null
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
          evidence_photo_path: string | null
          fully_paid_at: string | null
          home_id: string
          id: string
          notes: string | null
          plan_id: string | null
          recurrence_every: number | null
          recurrence_interval:
            | Database["public"]["Enums"]["recurrence_interval"]
            | null
          recurrence_unit: string | null
          split_type: Database["public"]["Enums"]["expense_split_type"] | null
          start_date: string
          status: Database["public"]["Enums"]["expense_status"]
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "expenses"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      expenses_get_created_by_me: { Args: { p_home_id: string }; Returns: Json }
      expenses_get_current_owed: { Args: { p_home_id: string }; Returns: Json }
      expenses_get_current_owed_v3: {
        Args: { p_home_id: string }
        Returns: Json
      }
      expenses_get_current_paid_to_me_by_debtor_details: {
        Args: { p_debtor_user_id: string; p_home_id: string }
        Returns: Json
      }
      expenses_get_current_paid_to_me_debtors: {
        Args: { p_home_id: string }
        Returns: Json
      }
      expenses_get_for_edit: { Args: { p_expense_id: string }; Returns: Json }
      expenses_get_for_edit_v3: {
        Args: { p_expense_id: string }
        Returns: Json
      }
      expenses_mark_paid_received_viewed_for_debtor: {
        Args: { p_debtor_user_id: string; p_home_id: string }
        Returns: Json
      }
      expenses_pay_my_due: {
        Args: { p_recipient_user_id: string }
        Returns: Json
      }
      expenses_pay_unit_due_v2: {
        Args: {
          p_amount_cents: number
          p_expense_id: string
          p_unit_id: string
        }
        Returns: Json
      }
      fail_complaint_rewrite_job: {
        Args: { p_error: string; p_job_id: string }
        Returns: undefined
      }
      fit_check_attach_draft_to_home: {
        Args: { p_draft_id: string; p_home_id: string }
        Returns: Json
      }
      fit_check_claim_draft: { Args: { p_claim_token: string }; Returns: Json }
      fit_check_cleanup_rate_limits: {
        Args: { p_older_than?: string }
        Returns: number
      }
      fit_check_get_owner_briefing: {
        Args: { p_locale?: string; p_submission_id: string }
        Returns: Json
      }
      fit_check_get_owner_review: {
        Args: { p_draft_id: string; p_locale?: string }
        Returns: Json
      }
      fit_check_get_prefill_payload: {
        Args: { p_draft_id: string }
        Returns: Json
      }
      fit_check_get_public_by_token: {
        Args: { p_locale?: string; p_share_token: string }
        Returns: Json
      }
      fit_check_revoke_share_token: {
        Args: { p_draft_id: string }
        Returns: Json
      }
      fit_check_rotate_share_token: {
        Args: { p_draft_id: string }
        Returns: Json
      }
      fit_check_submit_candidate_by_token: {
        Args: {
          p_answers?: Json
          p_display_name?: string
          p_locale?: string
          p_share_token: string
        }
        Returns: Json
      }
      fit_check_upsert_draft: {
        Args: {
          p_answers?: Json
          p_draft_id?: string
          p_draft_session_token?: string
          p_locale?: string
        }
        Returns: Json
      }
      get_home_directory_content: { Args: { p_home_id: string }; Returns: Json }
      get_home_directory_member_cards: { Args: never; Returns: Json }
      get_home_directory_wifi: { Args: { p_home_id: string }; Returns: Json }
      get_member_bank_account: {
        Args: { p_target_user_id: string }
        Returns: Json
      }
      get_member_directory_bank_account: { Args: never; Returns: Json }
      get_member_directory_notes: {
        Args: { p_target_user_id?: string }
        Returns: Json
      }
      get_member_directory_nudge: { Args: never; Returns: Json }
      get_plan_status: { Args: never; Returns: Json }
      gratitude_wall_list: {
        Args: {
          p_cursor_created_at?: string
          p_cursor_id?: string
          p_home_id: string
          p_limit?: number
        }
        Returns: {
          author_avatar_url: string
          author_user_id: string
          author_username: string
          created_at: string
          message: string
          mood: Database["public"]["Enums"]["mood_scale"]
          post_id: string
        }[]
      }
      gratitude_wall_mark_read: {
        Args: { p_home_id: string }
        Returns: boolean
      }
      gratitude_wall_stats: {
        Args: { p_home_id: string }
        Returns: {
          last_read_at: string
          total_posts: number
          unread_count: number
        }[]
      }
      gratitude_wall_status: {
        Args: { p_home_id: string }
        Returns: {
          has_unread: boolean
          last_read_at: string
        }[]
      }
      home_assignees_list: {
        Args: { p_home_id: string }
        Returns: {
          avatar_storage_path: string
          email: string
          full_name: string
          user_id: string
        }[]
      }
      home_assignees_list_v2: {
        Args: { p_home_id: string }
        Returns: {
          avatar_storage_path: string
          email: string
          full_name: string
          user_id: string
          username: string
        }[]
      }
      home_entitlements_refresh: {
        Args: { _home_id: string }
        Returns: undefined
      }
      home_nps_get_status: { Args: { p_home_id: string }; Returns: boolean }
      home_nps_submit: {
        Args: { p_home_id: string; p_score: number }
        Returns: {
          created_at: string
          home_id: string
          id: string
          nps_feedback_count: number
          score: number
          user_id: string
        }
        SetofOptions: {
          from: "*"
          to: "home_nps"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      home_units_create_shared: {
        Args: { p_home_id: string; p_membership_ids: string[]; p_name: string }
        Returns: string
      }
      home_units_get_my_context: { Args: { p_home_id: string }; Returns: Json }
      home_units_join_shared: { Args: { p_unit_id: string }; Returns: string }
      home_units_leave_shared: { Args: { p_unit_id: string }; Returns: string }
      home_units_list_create_shared_candidates: {
        Args: { p_home_id: string }
        Returns: {
          avatar_url: string
          display_name: string
          is_owner: boolean
          membership_id: string
          user_id: string
        }[]
      }
      home_units_list_joinable_shared_units: {
        Args: { p_home_id: string }
        Returns: {
          home_id: string
          member_user_ids: string[]
          name: string
          unit_id: string
          unit_type: string
        }[]
      }
      home_units_list_selectable_expense_units: {
        Args: { p_home_id: string }
        Returns: {
          home_id: string
          member_user_ids: string[]
          name: string
          unit_id: string
          unit_type: string
        }[]
      }
      home_units_update_shared: {
        Args: { p_name: string; p_unit_id: string }
        Returns: string
      }
      homes_create_with_invite: { Args: never; Returns: Json }
      homes_join: { Args: { p_code: string }; Returns: Json }
      homes_leave: { Args: { p_home_id: string }; Returns: Json }
      homes_transfer_owner: {
        Args: { p_home_id: string; p_new_owner_id: string }
        Returns: Json
      }
      house_norms_edit_section_text: {
        Args: {
          p_change_summary?: string
          p_home_id: string
          p_locale: string
          p_new_text: string
          p_section_key: string
        }
        Returns: Json
      }
      house_norms_generate_for_home: {
        Args: {
          p_force?: boolean
          p_home_id: string
          p_inputs: Json
          p_locale: string
          p_template_key: string
        }
        Returns: Json
      }
      house_norms_get_for_home: {
        Args: { p_home_id: string; p_locale: string }
        Returns: Json
      }
      house_norms_get_public_by_home_public_id: {
        Args: { p_home_public_id: string; p_locale: string }
        Returns: Json
      }
      house_norms_publish_for_home: {
        Args: { p_home_id: string; p_locale: string }
        Returns: Json
      }
      house_norms_publish_job_mark_failed: {
        Args: {
          p_error?: string
          p_error_code?: string
          p_job_id: string
          p_manifest_upload_ms?: number
          p_request_id?: string
          p_revalidate_ms?: number
          p_snapshot_upload_ms?: number
          p_stage?: string
        }
        Returns: Json
      }
      house_norms_publish_job_mark_processing: {
        Args: { p_job_id: string; p_request_id?: string; p_stage?: string }
        Returns: Json
      }
      house_norms_publish_job_mark_succeeded: {
        Args: {
          p_job_id: string
          p_manifest_upload_ms?: number
          p_request_id?: string
          p_revalidate_ms?: number
          p_snapshot_upload_ms?: number
        }
        Returns: Json
      }
      house_norms_publish_job_redrive_v1: {
        Args: { p_job_id: string }
        Returns: Json
      }
      house_norms_publish_jobs_dispatch_queued_v1: {
        Args: { p_limit?: number; p_stale_for?: string }
        Returns: Json
      }
      house_norms_record_view: { Args: { p_home_id: string }; Returns: Json }
      house_norms_should_show_member_review: {
        Args: { p_home_id: string }
        Returns: boolean
      }
      house_pulse_compute_week: {
        Args: {
          p_contract_version?: string
          p_home_id: string
          p_iso_week?: number
          p_iso_week_year?: number
        }
        Returns: {
          care_present: boolean
          complexity_present: boolean
          computed_at: string
          contract_version: string
          friction_present: boolean
          home_id: string
          iso_week: number
          iso_week_year: number
          member_count: number
          pulse_state: Database["public"]["Enums"]["house_pulse_state"]
          reflection_count: number
          weather_display: Database["public"]["Enums"]["mood_scale"] | null
        }
        SetofOptions: {
          from: "*"
          to: "house_pulse_weekly"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      house_pulse_label_get_v1: {
        Args: {
          p_contract_version?: string
          p_pulse_state: Database["public"]["Enums"]["house_pulse_state"]
        }
        Returns: {
          contract_version: string
          image_key: string
          pulse_state: Database["public"]["Enums"]["house_pulse_state"]
          summary_key: string
          title_key: string
          ui: Json
        }[]
      }
      house_pulse_mark_seen: {
        Args: {
          p_contract_version?: string
          p_home_id: string
          p_iso_week?: number
          p_iso_week_year?: number
        }
        Returns: {
          contract_version: string
          home_id: string
          iso_week: number
          iso_week_year: number
          last_seen_computed_at: string
          last_seen_pulse_state: Database["public"]["Enums"]["house_pulse_state"]
          seen_at: string
          user_id: string
        }
        SetofOptions: {
          from: "*"
          to: "house_pulse_reads"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      house_pulse_weekly_get: {
        Args: {
          p_contract_version?: string
          p_home_id: string
          p_iso_week?: number
          p_iso_week_year?: number
        }
        Returns: Json
      }
      house_vibe_compute: {
        Args: { p_force?: boolean; p_home_id: string; p_include_axes?: boolean }
        Returns: Json
      }
      invites_get_active: {
        Args: { p_home_id: string }
        Returns: {
          code: string
          created_at: string
          home_id: string
          id: string
          revoked_at: string | null
          used_count: number
        }
        SetofOptions: {
          from: "*"
          to: "invites"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      invites_revoke: { Args: { p_home_id: string }; Returns: Json }
      invites_rotate: { Args: { p_home_id: string }; Returns: Json }
      is_home_owner: {
        Args: { p_home_id: string; p_user_id?: string }
        Returns: boolean
      }
      leads_rate_limits_cleanup: { Args: never; Returns: undefined }
      leads_upsert_v1: {
        Args: {
          p_country_code: string
          p_email: string
          p_source?: string
          p_ui_locale: string
        }
        Returns: Json
      }
      list_due_home_directory_reminders: {
        Args: { p_home_id: string }
        Returns: Json
      }
      locale_base: { Args: { p_locale: string }; Returns: string }
      map_instruction: {
        Args: { p_id: string; p_value: string }
        Returns: string
      }
      mark_rewrite_jobs_batch_submitted_v1: {
        Args: { p_job_ids: string[]; p_provider_batch_id: string }
        Returns: undefined
      }
      member_cap_owner_dismiss: {
        Args: { p_home_id: string }
        Returns: undefined
      }
      member_cap_process_pending: {
        Args: { p_home_id: string }
        Returns: undefined
      }
      members_kick: {
        Args: { p_home_id: string; p_target_user_id: string }
        Returns: Json
      }
      members_list_active_by_home: {
        Args: { p_exclude_self?: boolean; p_home_id: string }
        Returns: {
          avatar_url: string
          can_transfer_to: boolean
          role: string
          user_id: string
          username: string
          valid_from: string
        }[]
      }
      membership_me_current: { Args: never; Returns: Json }
      mood_get_current_weekly: { Args: { p_home_id: string }; Returns: boolean }
      mood_submit: {
        Args: {
          p_add_to_wall?: boolean
          p_comment?: string
          p_home_id: string
          p_mood: Database["public"]["Enums"]["mood_scale"]
        }
        Returns: {
          entry_id: string
          gratitude_post_id: string
        }[]
      }
      mood_submit_v2: {
        Args: {
          p_comment?: string
          p_home_id: string
          p_mentions?: string[]
          p_mood: Database["public"]["Enums"]["mood_scale"]
          p_public_wall?: boolean
        }
        Returns: Json
      }
      notifications_daily_candidates: {
        Args: { p_limit?: number; p_offset?: number }
        Returns: {
          local_date: string
          locale: string
          timezone: string
          token: string
          token_id: string
          user_id: string
        }[]
      }
      notifications_mark_send_success: {
        Args: { p_local_date: string; p_send_id: string; p_user_id: string }
        Returns: undefined
      }
      notifications_mark_token_status: {
        Args: { p_status: string; p_token_id: string }
        Returns: undefined
      }
      notifications_reserve_send: {
        Args: {
          p_job_run_id: string
          p_local_date: string
          p_token_id: string
          p_user_id: string
        }
        Returns: string
      }
      notifications_sync_client_state: {
        Args: {
          p_locale: string
          p_os_permission: string
          p_platform: string
          p_preferred_hour?: number
          p_preferred_minute?: number
          p_timezone: string
          p_token: string
          p_wants_daily?: boolean
        }
        Returns: {
          created_at: string
          last_os_sync_at: string | null
          last_sent_local_date: string | null
          locale: string
          os_permission: string
          preferred_hour: number
          preferred_minute: number
          timezone: string
          updated_at: string
          user_id: string
          wants_daily: boolean
        }
        SetofOptions: {
          from: "*"
          to: "notification_preferences"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      notifications_update_preferences: {
        Args: {
          p_preferred_hour: number
          p_preferred_minute: number
          p_wants_daily: boolean
        }
        Returns: {
          created_at: string
          last_os_sync_at: string | null
          last_sent_local_date: string | null
          locale: string
          os_permission: string
          preferred_hour: number
          preferred_minute: number
          timezone: string
          updated_at: string
          user_id: string
          wants_daily: boolean
        }
        SetofOptions: {
          from: "*"
          to: "notification_preferences"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      notifications_update_send_status: {
        Args: { p_error: string; p_send_id: string; p_status: string }
        Returns: undefined
      }
      outreach_event_logs_cleanup: {
        Args: { p_keep?: string }
        Returns: number
      }
      outreach_log_event: {
        Args: {
          p_app_key: string
          p_client_event_id?: string
          p_country?: string
          p_event: string
          p_page_key: string
          p_session_id: string
          p_store?: string
          p_ui_locale?: string
          p_utm_campaign: string
          p_utm_medium: string
          p_utm_source: string
        }
        Returns: Json
      }
      outreach_poll_get_v1: {
        Args: { p_app_key: string; p_page_key: string }
        Returns: Json
      }
      outreach_poll_vote_submit_v1: {
        Args: {
          p_client_vote_id?: string
          p_country?: string
          p_option_key: string
          p_session_id: string
          p_short_code: string
          p_store?: string
          p_ui_locale?: string
        }
        Returns: Json
      }
      outreach_rate_limits_cleanup: {
        Args: { p_keep?: string }
        Returns: number
      }
      outreach_short_links_disable: {
        Args: { p_short_code: string }
        Returns: Json
      }
      outreach_short_links_get_or_create: {
        Args: {
          p_app_key?: string
          p_expires_at?: string
          p_page_key?: string
          p_short_code?: string
          p_target_path?: string
          p_target_query?: Json
          p_utm_campaign?: string
          p_utm_medium?: string
          p_utm_source?: string
        }
        Returns: Json
      }
      paywall_log_event: {
        Args: { p_event_type: string; p_home_id: string; p_source?: string }
        Returns: undefined
      }
      paywall_record_subscription: {
        Args: {
          p_current_period_end_at: string
          p_entitlement_id: string
          p_entitlement_ids?: string[]
          p_environment?: string
          p_event_timestamp?: string
          p_home_id: string
          p_idempotency_key: string
          p_last_purchase_at: string
          p_latest_transaction_id: string
          p_original_purchase_at: string
          p_original_transaction_id?: string
          p_product_id: string
          p_raw_event?: Json
          p_rc_app_user_id: string
          p_rc_event_id?: string
          p_status: Database["public"]["Enums"]["subscription_status"]
          p_store: Database["public"]["Enums"]["subscription_store"]
          p_user_id: string
          p_warnings?: string[]
        }
        Returns: boolean
      }
      paywall_status_get: { Args: { p_home_id: string }; Returns: Json }
      personal_gratitude_inbox_list_v1: {
        Args: { p_before_at?: string; p_before_id?: string; p_limit?: number }
        Returns: {
          author_avatar_id: string
          author_avatar_path: string
          author_user_id: string
          author_username: string
          created_at: string
          home_id: string
          id: string
          message: string
          mood: Database["public"]["Enums"]["mood_scale"]
          source_entry_id: string
          source_kind: string
          source_post_id: string
        }[]
      }
      personal_gratitude_showcase_stats_v1: {
        Args: { p_exclude_self?: boolean }
        Returns: Json
      }
      personal_gratitude_wall_mark_read_v1: { Args: never; Returns: boolean }
      personal_gratitude_wall_status_v1: {
        Args: never
        Returns: {
          has_unread: boolean
          last_read_at: string
        }[]
      }
      preference_reports_acknowledge: {
        Args: { p_report_id: string }
        Returns: Json
      }
      preference_reports_edit_section_text: {
        Args: {
          p_change_summary?: string
          p_locale: string
          p_new_text: string
          p_section_key: string
          p_template_key: string
        }
        Returns: Json
      }
      preference_reports_generate: {
        Args: { p_force?: boolean; p_locale: string; p_template_key: string }
        Returns: Json
      }
      preference_reports_get_for_home: {
        Args: {
          p_home_id: string
          p_locale: string
          p_subject_user_id: string
          p_template_key: string
        }
        Returns: Json
      }
      preference_reports_get_personal_v1: {
        Args: { p_locale?: string; p_template_key?: string }
        Returns: Json
      }
      preference_reports_list_for_home: {
        Args: { p_home_id: string; p_locale: string; p_template_key: string }
        Returns: Json
      }
      preference_responses_submit: { Args: { p_answers: Json }; Returns: Json }
      preference_templates_get_for_user: {
        Args: { p_template_key?: string }
        Returns: Json
      }
      profile_identity_update: {
        Args: { p_avatar_id: string; p_username: string }
        Returns: {
          avatar_id: string
          avatar_storage_path: string
          username: string
        }[]
      }
      profile_me: {
        Args: never
        Returns: {
          avatar_storage_path: string
          user_id: string
          username: string
        }[]
      }
      profiles_request_deactivation: { Args: never; Returns: Json }
      requeue_jobs_after_submit_failure: {
        Args: {
          p_backoff_seconds?: number
          p_error: string
          p_job_ids: string[]
        }
        Returns: undefined
      }
      rewrite_batch_collector_dispatch_v1: { Args: never; Returns: Json }
      rewrite_batch_list_pending_v1: {
        Args: { p_limit?: number }
        Returns: {
          endpoint: string
          error_file_id: string
          input_file_id: string
          output_file_id: string
          provider_batch_id: string
          status: string
        }[]
      }
      rewrite_batch_register_v1: {
        Args: {
          p_endpoint?: string
          p_input_file_id: string
          p_job_count: number
          p_provider_batch_id: string
        }
        Returns: undefined
      }
      rewrite_batch_submitter_dispatch_v1: { Args: never; Returns: Json }
      rewrite_batch_update_v1: {
        Args: {
          p_error_file_id?: string
          p_output_file_id?: string
          p_provider_batch_id: string
          p_status: string
        }
        Returns: undefined
      }
      rewrite_job_fetch_v1: {
        Args: { p_job_id: string }
        Returns: {
          job_id: string
          provider_batch_id: string
          recipient_user_id: string
          rewrite_request_id: string
          routing_decision: Json
          status: string
        }[]
      }
      rewrite_jobs_requeue_by_provider_batch_v1: {
        Args: {
          p_backoff_seconds?: number
          p_limit?: number
          p_provider_batch_id: string
          p_reason?: string
        }
        Returns: {
          job_id: string
          new_status: string
          not_before_at: string
          prev_status: string
        }[]
      }
      share_log_event: {
        Args: { p_channel: string; p_feature: string; p_home_id: string }
        Returns: undefined
      }
      shopping_list_add_item: {
        Args: {
          p_details?: string
          p_home_id: string
          p_name: string
          p_quantity?: string
          p_reference_photo_path?: string
        }
        Returns: {
          archived_at: string | null
          archived_by_user_id: string | null
          completed_at: string | null
          completed_by_user_id: string | null
          created_at: string
          created_by_user_id: string
          details: string | null
          home_id: string
          id: string
          is_completed: boolean
          linked_expense_id: string | null
          name: string
          quantity: string | null
          reference_added_by_user_id: string | null
          reference_photo_path: string | null
          scope_type: string
          shopping_list_id: string
          unit_id: string | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "shopping_list_items"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      shopping_list_add_item_v2: {
        Args: {
          p_details?: string
          p_home_id: string
          p_name: string
          p_quantity?: string
          p_reference_photo_path?: string
          p_scope_type?: string
          p_unit_id?: string
        }
        Returns: Json
      }
      shopping_list_archive_item: {
        Args: { p_item_id: string }
        Returns: {
          archived_at: string | null
          archived_by_user_id: string | null
          completed_at: string | null
          completed_by_user_id: string | null
          created_at: string
          created_by_user_id: string
          details: string | null
          home_id: string
          id: string
          is_completed: boolean
          linked_expense_id: string | null
          name: string
          quantity: string | null
          reference_added_by_user_id: string | null
          reference_photo_path: string | null
          scope_type: string
          shopping_list_id: string
          unit_id: string | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "shopping_list_items"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      shopping_list_archive_items_for_user: {
        Args: { p_home_id: string; p_item_ids: string[] }
        Returns: number
      }
      shopping_list_get_for_home: { Args: { p_home_id: string }; Returns: Json }
      shopping_list_get_for_home_v2: {
        Args: { p_home_id: string; p_scope_type?: string; p_unit_id?: string }
        Returns: Json
      }
      shopping_list_link_items_to_expense_for_user: {
        Args: { p_expense_id: string; p_home_id: string; p_item_ids: string[] }
        Returns: number
      }
      shopping_list_prepare_expense_for_user: {
        Args: { p_home_id: string }
        Returns: {
          default_description: string
          default_notes: string
          item_count: number
          item_ids: string[]
        }[]
      }
      shopping_list_update_item: {
        Args: {
          p_details?: string
          p_is_completed?: boolean
          p_item_id: string
          p_name?: string
          p_quantity?: string
          p_reference_photo_path?: string
          p_replace_photo?: boolean
        }
        Returns: {
          archived_at: string | null
          archived_by_user_id: string | null
          completed_at: string | null
          completed_by_user_id: string | null
          created_at: string
          created_by_user_id: string
          details: string | null
          home_id: string
          id: string
          is_completed: boolean
          linked_expense_id: string | null
          name: string
          quantity: string | null
          reference_added_by_user_id: string | null
          reference_photo_path: string | null
          scope_type: string
          shopping_list_id: string
          unit_id: string | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "shopping_list_items"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      shopping_list_update_item_v2: {
        Args: {
          p_details: string
          p_is_completed: boolean
          p_item_id: string
          p_name: string
          p_quantity: string
          p_reference_photo_path: string
          p_replace_photo: boolean
          p_scope_type: string
          p_unit_id: string
        }
        Returns: {
          archived_at: string | null
          archived_by_user_id: string | null
          completed_at: string | null
          completed_by_user_id: string | null
          created_at: string
          created_by_user_id: string
          details: string | null
          home_id: string
          id: string
          is_completed: boolean
          linked_expense_id: string | null
          name: string
          quantity: string | null
          reference_added_by_user_id: string | null
          reference_photo_path: string | null
          scope_type: string
          shopping_list_id: string
          unit_id: string | null
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "shopping_list_items"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      today_flow_list: {
        Args: {
          p_home_id: string
          p_local_date?: string
          p_state: Database["public"]["Enums"]["chore_state"]
        }
        Returns: {
          home_id: string
          id: string
          name: string
          start_date: string
          state: Database["public"]["Enums"]["chore_state"]
        }[]
      }
      today_has_content: {
        Args: { p_local_date: string; p_timezone: string; p_user_id: string }
        Returns: boolean
      }
      today_onboarding_hints: { Args: never; Returns: Json }
      update_member_directory_note: {
        Args: {
          p_contact_name?: string
          p_custom_title?: string
          p_details?: string
          p_label?: string
          p_note_id: string
          p_phone_number?: string
          p_photo_path?: string
        }
        Returns: Json
      }
      update_member_directory_note_v2: {
        Args: {
          p_contact_name?: string
          p_custom_title?: string
          p_details?: string
          p_label?: string
          p_note_id: string
          p_phone_number?: string
          p_photo_path?: string
          p_reference_url?: string
        }
        Returns: Json
      }
      upsert_home_directory_note: {
        Args: {
          p_details?: string
          p_home_id: string
          p_note_id?: string
          p_note_type?: string
          p_photo_path?: string
          p_reference_url?: string
          p_title?: string
        }
        Returns: Json
      }
      upsert_home_directory_service: {
        Args: {
          p_account_reference?: string
          p_custom_label?: string
          p_home_id: string
          p_link_url?: string
          p_notes?: string
          p_provider_name?: string
          p_renewal_reminder_offset_unit?: string
          p_renewal_reminder_offset_value?: number
          p_service_id?: string
          p_service_type?: string
          p_term_end_date?: string
          p_term_start_date?: string
        }
        Returns: Json
      }
      upsert_home_directory_wifi: {
        Args: { p_home_id: string; p_password?: string; p_ssid: string }
        Returns: Json
      }
      upsert_member_directory_bank_account: {
        Args: { p_account_holder_name: string; p_account_number: string }
        Returns: Json
      }
      user_context_v1: { Args: never; Returns: Json }
      withyou_log_pack_download_v1: {
        Args: {
          p_app_version?: string
          p_country_code?: string
          p_language: string
          p_pack_version?: string
          p_platform?: string
          p_request_path?: string
          p_user_agent?: string
        }
        Returns: Json
      }
    }
    Enums: {
      chore_event_type: "create" | "activate" | "update" | "complete" | "cancel"
      chore_state: "draft" | "active" | "completed" | "cancelled"
      expense_plan_status: "active" | "terminated"
      expense_share_status: "unpaid" | "paid"
      expense_split_type: "equal" | "custom"
      expense_status: "draft" | "active" | "cancelled" | "converted"
      home_usage_metric:
        | "active_chores"
        | "chore_photos"
        | "active_members"
        | "active_expenses"
        | "shopping_item_photos"
        | "expense_photos"
        | "house_directory_note_photos"
      house_pulse_state:
        | "forming"
        | "sunny_calm"
        | "sunny_bumpy"
        | "partly_supported"
        | "cloudy_steady"
        | "cloudy_tense"
        | "rainy_supported"
        | "rainy_unsupported"
        | "thunderstorm"
      mood_scale:
        | "sunny"
        | "partially_sunny"
        | "cloudy"
        | "rainy"
        | "thunderstorm"
      recurrence_interval:
        | "none"
        | "daily"
        | "weekly"
        | "every_2_weeks"
        | "monthly"
        | "every_2_months"
        | "annual"
      revenuecat_processing_status: "processing" | "succeeded" | "failed"
      subscription_status: "active" | "cancelled" | "expired" | "inactive"
      subscription_store: "app_store" | "play_store" | "stripe" | "promotional"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  graphql_public: {
    Enums: {},
  },
  public: {
    Enums: {
      chore_event_type: ["create", "activate", "update", "complete", "cancel"],
      chore_state: ["draft", "active", "completed", "cancelled"],
      expense_plan_status: ["active", "terminated"],
      expense_share_status: ["unpaid", "paid"],
      expense_split_type: ["equal", "custom"],
      expense_status: ["draft", "active", "cancelled", "converted"],
      home_usage_metric: [
        "active_chores",
        "chore_photos",
        "active_members",
        "active_expenses",
        "shopping_item_photos",
        "expense_photos",
        "house_directory_note_photos",
      ],
      house_pulse_state: [
        "forming",
        "sunny_calm",
        "sunny_bumpy",
        "partly_supported",
        "cloudy_steady",
        "cloudy_tense",
        "rainy_supported",
        "rainy_unsupported",
        "thunderstorm",
      ],
      mood_scale: [
        "sunny",
        "partially_sunny",
        "cloudy",
        "rainy",
        "thunderstorm",
      ],
      recurrence_interval: [
        "none",
        "daily",
        "weekly",
        "every_2_weeks",
        "monthly",
        "every_2_months",
        "annual",
      ],
      revenuecat_processing_status: ["processing", "succeeded", "failed"],
      subscription_status: ["active", "cancelled", "expired", "inactive"],
      subscription_store: ["app_store", "play_store", "stripe", "promotional"],
    },
  },
} as const

