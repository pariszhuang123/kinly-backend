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
      expense_plans: {
        Row: {
          amount_cents: number
          created_at: string
          created_by_user_id: string
          description: string
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
          updated_at: string
        }
        Insert: {
          amount_cents: number
          created_at?: string
          created_by_user_id: string
          description: string
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
          updated_at?: string
        }
        Update: {
          amount_cents?: number
          created_at?: string
          created_by_user_id?: string
          description?: string
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
      expenses: {
        Row: {
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
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
          amount_cents?: number | null
          created_at?: string
          created_by_user_id: string
          description: string
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
          amount_cents?: number | null
          created_at?: string
          created_by_user_id?: string
          description?: string
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
      home_usage_counters: {
        Row: {
          active_chores: number
          active_expenses: number
          active_members: number
          chore_photos: number
          home_id: string
          updated_at: string
        }
        Insert: {
          active_chores?: number
          active_expenses?: number
          active_members?: number
          chore_photos?: number
          home_id: string
          updated_at?: string
        }
        Update: {
          active_chores?: number
          active_expenses?: number
          active_members?: number
          chore_photos?: number
          home_id?: string
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
      shared_preferences: {
        Row: {
          created_at: string
          pref_key: string
          pref_value: Json
          updated_at: string
          user_id: string
        }
        Insert: {
          created_at?: string
          pref_key: string
          pref_value?: Json
          updated_at?: string
          user_id: string
        }
        Update: {
          created_at?: string
          pref_key?: string
          pref_value?: Json
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shared_preferences_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "profiles"
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
    }
    Views: {
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
      _current_user_id: { Args: never; Returns: string }
      _ensure_unique_avatar_for_home: {
        Args: { p_home_id: string; p_user_id: string }
        Returns: string
      }
      _expense_plan_generate_cycle: {
        Args: { p_cycle_date: string; p_plan_id: string }
        Returns: {
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
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
      _home_usage_apply_delta: {
        Args: { p_deltas: Json; p_home_id: string }
        Returns: {
          active_chores: number
          active_expenses: number
          active_members: number
          chore_photos: number
          home_id: string
          updated_at: string
        }
        SetofOptions: {
          from: "*"
          to: "home_usage_counters"
          isOneToOne: true
          isSetofReturn: false
        }
      }
      _house_vibe_confidence_kind: {
        Args: { p_label_id: string }
        Returns: string
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
      _outreach_rate_limit_bucketed: {
        Args: { p_bucket_start: string; p_key: string; p_limit: number }
        Returns: boolean
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
      expense_plans_generate_due_cycles: { Args: never; Returns: undefined }
      expense_plans_terminate: {
        Args: { p_plan_id: string }
        Returns: {
          amount_cents: number
          created_at: string
          created_by_user_id: string
          description: string
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
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
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
              amount_cents: number | null
              created_at: string
              created_by_user_id: string
              description: string
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
              amount_cents: number | null
              created_at: string
              created_by_user_id: string
              description: string
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
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
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
              amount_cents: number | null
              created_at: string
              created_by_user_id: string
              description: string
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
              amount_cents: number | null
              created_at: string
              created_by_user_id: string
              description: string
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
          amount_cents: number | null
          created_at: string
          created_by_user_id: string
          description: string
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
      expenses_get_current_paid_to_me_by_debtor_details: {
        Args: { p_debtor_user_id: string; p_home_id: string }
        Returns: Json
      }
      expenses_get_current_paid_to_me_debtors: {
        Args: { p_home_id: string }
        Returns: Json
      }
      expenses_get_for_edit: { Args: { p_expense_id: string }; Returns: Json }
      expenses_mark_paid_received_viewed_for_debtor: {
        Args: { p_debtor_user_id: string; p_home_id: string }
        Returns: Json
      }
      expenses_pay_my_due: {
        Args: { p_recipient_user_id: string }
        Returns: Json
      }
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
      homes_create_with_invite: { Args: never; Returns: Json }
      homes_join: { Args: { p_code: string }; Returns: Json }
      homes_leave: { Args: { p_home_id: string }; Returns: Json }
      homes_transfer_owner: {
        Args: { p_home_id: string; p_new_owner_id: string }
        Returns: Json
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
      locale_base: { Args: { p_locale: string }; Returns: string }
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
      outreach_rate_limits_cleanup: {
        Args: { p_keep?: string }
        Returns: number
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
      share_log_event: {
        Args: { p_channel: string; p_feature: string; p_home_id: string }
        Returns: undefined
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
      user_context_v1: {
        Args: never
        Returns: {
          avatar_storage_path: string
          display_name: string
          has_personal_mentions: boolean
          has_preference_report: boolean
          show_avatar: boolean
          user_id: string
        }[]
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

