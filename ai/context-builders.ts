import type { SupabaseClient } from "@supabase/supabase-js";

import { getDocumentChunksForServiceOrder } from "./retrieval";

async function getTemplateContext(supabaseService: SupabaseClient, templateId: string) {
  const { data: template, error } = await (supabaseService as any)
    .from("document_templates")
    .select("id, template_name, document_type, base_language, description, template_content")
    .eq("id", templateId)
    .single();

  if (error) {
    throw error;
  }

  return template;
}

async function getServiceOrderSummaryContext(supabaseService: SupabaseClient, serviceOrderId: string) {
  const { data: order, error } = await (supabaseService as any)
    .from("service_orders")
    .select(`
      *,
      clients(name),
      service_master(name),
      service_order_stages(*, service_order_tasks(*)),
      service_order_task_documents(*),
      order_cases(
        *,
        courts:court_id(court_name),
        case_hearings(
          *,
          courts:court_id(court_name),
          hearing_participants(*)
        )
      )
    `)
    .eq("id", serviceOrderId)
    .single();

  if (error) {
    throw error;
  }

  const stages = Array.isArray((order as any).service_order_stages) ? (order as any).service_order_stages : [];
  const tasks = stages.flatMap((stage: any) => stage.service_order_tasks || []);
  const taskHearings = tasks
    .filter((task: any) => task.hearing_date || task.hearing_time)
    .map((task: any) => ({
      source: "task" as const,
      name: task.name,
      hearing_date: task.hearing_date,
      hearing_time: task.hearing_time,
    }));
  const documents = Array.isArray((order as any).service_order_task_documents)
    ? (order as any).service_order_task_documents
    : [];
  const orderCases = Array.isArray((order as any).order_cases) ? (order as any).order_cases : [];

  const cases = orderCases.map((caseRow: any) => {
    const caseHearings = Array.isArray(caseRow.case_hearings) ? caseRow.case_hearings : [];
    return {
      id: caseRow.id,
      case_title: caseRow.case_title,
      case_number: caseRow.case_number,
      case_type: caseRow.case_type,
      status: caseRow.status,
      court_name: caseRow.courts?.court_name || null,
      notes: caseRow.notes,
      hearings: caseHearings.map((hearing: any) => ({
        id: hearing.id,
        hearing_number: hearing.hearing_number,
        hearing_date: hearing.hearing_date,
        hearing_time: hearing.hearing_time,
        purpose: hearing.purpose,
        status: hearing.status,
        notes: hearing.notes,
        court_name: hearing.courts?.court_name || null,
        participants: (Array.isArray(hearing.hearing_participants) ? hearing.hearing_participants : [])
          .map((participant: any) => ({
            participant_type: participant.participant_type,
            name: participant.name,
            notes: participant.notes,
          })),
      })),
    };
  });

  const courtHearings = cases.flatMap((caseRow: any) =>
    (caseRow.hearings || []).map((hearing: any) => ({
      source: "court_case" as const,
      case_title: caseRow.case_title,
      case_number: caseRow.case_number,
      court_name: hearing.court_name || caseRow.court_name,
      hearing_number: hearing.hearing_number,
      hearing_date: hearing.hearing_date,
      hearing_time: hearing.hearing_time,
      purpose: hearing.purpose,
      status: hearing.status,
    }))
  );

  return {
    order_number: order.order_number,
    client_name: (order as any).clients?.name || order.client_name || null,
    service_name: (order as any).service_master?.name || order.service_name || null,
    status: order.status,
    updated_at: order.updated_at,
    notes: order.notes,
    legal_templates: order.legal_templates,
    stages: stages.map((stage: any) => ({
      id: stage.id,
      name: stage.name,
      status: stage.status,
      notes: stage.notes,
      tasks: (stage.service_order_tasks || []).map((task: any) => ({
        id: task.id,
        name: task.name,
        status: task.status,
        description: task.description,
        priority: task.priority,
        hearing_date: task.hearing_date,
        hearing_time: task.hearing_time,
      })),
    })),
    tasks: tasks.map((task: any) => ({
      id: task.id,
      name: task.name,
      status: task.status,
      description: task.description,
      priority: task.priority,
      hearing_date: task.hearing_date,
      hearing_time: task.hearing_time,
    })),
    cases,
    hearings: [...taskHearings, ...courtHearings],
    documents: documents.map((doc: any) => ({
      id: doc.id,
      document_name: doc.document_name,
      file_type: doc.file_type,
      is_uploaded: doc.is_uploaded,
      uploaded_at: doc.uploaded_at,
      provided_by: doc.provided_by,
    })),
  };
}

export async function buildFeatureContext(
  supabaseService: SupabaseClient,
  feature: string,
  payload: Record<string, any>
) {
  switch (feature) {
    case "template_drafting": {
      const baseTemplate = payload.templateId
        ? await getTemplateContext(supabaseService, payload.templateId)
        : {
            template_name: payload.templateName,
            document_type: payload.documentType,
            base_language: payload.baseLanguage,
            description: payload.description,
            template_content: "",
          };
      const context: Record<string, any> = {
        ...baseTemplate,
        description: payload.description || baseTemplate.description,
        template_content: payload.templateContent ?? baseTemplate.template_content ?? "",
        placeholders: payload.placeholders || [],
      };
      if (payload.toLanguage) {
        context.from_language = payload.fromLanguage || baseTemplate.base_language || null;
        context.to_language = payload.toLanguage;
      }
      return context;
    }
    case "service_order_summary":
      return getServiceOrderSummaryContext(supabaseService, payload.serviceOrderId);
    case "document_summarizer":
      return {
        serviceOrderId: payload.serviceOrderId,
        documentIds: payload.documentIds || [],
        documentName: payload.documentName || null,
        documentText: payload.documentText || null,
        summaryType: payload.summaryType || "document",
      };
    case "legal_research":
      return {
        serviceOrderId: payload.serviceOrderId,
        question: payload.question,
        internalChunks: payload.serviceOrderId
          ? await getDocumentChunksForServiceOrder(supabaseService, payload.serviceOrderId, 15)
          : [],
        externalSources: payload.externalSources || [],
      };
    case "stage_task_suggestions":
    case "service_master_suggestions":
      return {
        serviceName: payload.serviceName,
        categoryName: payload.categoryName,
        description: payload.description,
        workTypes: payload.workTypes || [],
        availableWorkTypes: payload.availableWorkTypes || [],
        availableDocuments: payload.availableDocuments || [],
        legalTemplates: payload.legalTemplates || [],
        requiredDocuments: payload.requiredDocuments || [],
        existingStages: payload.existingStages || [],
        userInstruction: payload.userInstruction || null,
      };
    case "general_chat":
      return {
        messages: Array.isArray(payload.messages) ? payload.messages : [],
        userQuestion: payload.userQuestion || payload.question || "",
      };
    case "seo_suggestions":
      return {
        firm_name: payload.firmName || null,
        tagline: payload.tagline || null,
        hero_title: payload.hero?.title || null,
        hero_description: payload.hero?.description || null,
        about_title: payload.about?.title || null,
        about_description: payload.about?.description || null,
        about_points: payload.about?.points || [],
        services: (payload.services || []).map((s: any) => ({
          title: s.title || s.name || "",
          description: s.desc || s.description || "",
        })),
        locations: payload.locations || [],
        business_info: payload.businessInfo || null,
        why_us_points: payload.whyUsPoints || [],
        stats: payload.stats || [],
        canonical_url: payload.canonicalUrl || null,
        existing_seo: payload.existingSeo || {},
        userInstruction: payload.userInstruction || null,
      };
    default:
      return payload;
  }
}
