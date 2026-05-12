// AI Website Generation Prompts
// These prompts are used by Claude Sonnet and Groq models to generate website HTML

// Claude API Prompt Template
const CLAUDE_WEBSITE_PROMPT = `You are an expert web designer creating a beautiful, modern website for a business.

BUSINESS DETAILS:
- Shop Name: {SHOP_NAME}
- Business Type: {BUSINESS_TYPE}
- Headline: {WEBSITE_HEADLINE}
- Description: {WEBSITE_DESCRIPTION}
- Design Style: {DESIGN_STYLE}

COLOR SCHEME (IMPORTANT - Use exactly these colors):
- Primary Color: {COLOR_PRIMARY_NAME} ({COLOR_PRIMARY_HEX})
- Accent Color: {COLOR_ACCENT_NAME} ({COLOR_ACCENT_HEX})
- Use primary color as background or header
- Use accent color for buttons, links, and highlights
- Ensure good contrast for readability

REQUIREMENTS:
✓ Generate clean, valid HTML5 with embedded CSS
✓ Mobile-responsive (mobile-first approach)
✓ Modern, professional design matching the {DESIGN_STYLE} style
✓ {PAGES_COUNT} page(s) total
✓ Fast-loading (optimize images with lazy-loading)
✓ SEO-friendly (semantic HTML, proper headings)
✓ Accessibility (WCAG AA standard, good contrast ratios)
✓ Professional typography with good hierarchy
✓ Clear call-to-action buttons
✓ Contact section with WhatsApp and email
✓ Responsive navigation menu
✓ Hero section with headline
✓ Service/Product showcase
✓ Footer with social links

DESIGN GUIDELINES:
- Use {COLOR_PRIMARY_HEX} as primary background/header
- Use {COLOR_ACCENT_HEX} for buttons and interactive elements
- Keep typography clean and readable
- Use ample white space
- Add subtle shadows for depth
- Make buttons clear with good hover states
- Ensure mobile navigation works perfectly
- No external dependencies (only pure HTML/CSS/minimal JS)

OUTPUT:
- Single HTML file (self-contained with <style> tag)
- Include Font Awesome icons via CDN (optional, for icons)
- Ready to deploy immediately
- Professional quality, production-ready
- Dark mode friendly CSS custom properties

Start with <!DOCTYPE html> and provide complete, valid HTML.`;

// Groq API Prompt Template
const GROQ_WEBSITE_PROMPT = `Generate a beautiful HTML website for:

Business: {SHOP_NAME} ({BUSINESS_TYPE})
Headline: {WEBSITE_HEADLINE}
Description: {WEBSITE_DESCRIPTION}
Style: {DESIGN_STYLE}

COLORS:
Primary: {COLOR_PRIMARY_NAME} ({COLOR_PRIMARY_HEX})
Accent: {COLOR_ACCENT_NAME} ({COLOR_ACCENT_HEX})

Build:
- HTML5 + CSS3 (no frameworks)
- {PAGES_COUNT} pages
- Mobile responsive
- Professional design
- Fast loading
- Semantic HTML
- Good contrast
- Clear CTAs
- WhatsApp/email contact

Return only valid HTML code. Make it look amazing.`;

// Edge Function Handler (Supabase)
const EDGE_FUNCTION_HANDLER = `
import Anthropic from "@anthropic-ai/sdk";
import { createClient } from "@supabase/supabase-js";

const anthropic = new Anthropic({
  apiKey: Deno.env.get("ANTHROPIC_API_KEY"),
});

const supabase = createClient(
  Deno.env.get("SUPABASE_URL"),
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
);

const ACTIVE_PROVIDER = Deno.env.get("ACTIVE_AI_PROVIDER") || "claude";

Deno.serve(async (req) => {
  const { formData } = await req.json();

  try {
    // Build prompt with form data
    const prompt = buildPrompt(formData, ACTIVE_PROVIDER);

    let generatedHtml;

    if (ACTIVE_PROVIDER === "claude") {
      generatedHtml = await generateWithClaude(prompt);
    } else if (ACTIVE_PROVIDER === "groq") {
      generatedHtml = await generateWithGroq(prompt);
    } else {
      throw new Error("Unknown AI provider");
    }

    // Save to database
    const { error: dbError } = await supabase.rpc(
      "sbp_generate_website",
      {
        p_form_data: {
          ...formData,
          generated_html: generatedHtml,
          provider: ACTIVE_PROVIDER,
        },
      }
    );

    if (dbError) throw dbError;

    return new Response(
      JSON.stringify({
        ok: true,
        message: "Website generated successfully",
        html_preview: generatedHtml.substring(0, 500),
      }),
      { headers: { "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("Generation error:", error);

    // Log error for admin
    await supabase.from("generation_errors").insert({
      provider: ACTIVE_PROVIDER,
      error: error.message,
      form_data: formData,
      timestamp: new Date(),
    });

    return new Response(
      JSON.stringify({
        ok: false,
        error: "generation_failed",
        message: error.message,
      }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }
});

function buildPrompt(formData, provider) {
  const template =
    provider === "claude"
      ? CLAUDE_WEBSITE_PROMPT
      : GROQ_WEBSITE_PROMPT;

  return template
    .replace("{SHOP_NAME}", formData.shop_name)
    .replace("{BUSINESS_TYPE}", formData.business_type)
    .replace("{WEBSITE_HEADLINE}", formData.website_headline)
    .replace("{WEBSITE_DESCRIPTION}", formData.website_description)
    .replace("{DESIGN_STYLE}", formData.design_style)
    .replace("{COLOR_PRIMARY_NAME}", capitalizeWord(formData.color_primary))
    .replace("{COLOR_PRIMARY_HEX}", formData.color_primary_hex)
    .replace("{COLOR_ACCENT_NAME}", capitalizeWord(formData.color_accent))
    .replace("{COLOR_ACCENT_HEX}", formData.color_accent_hex)
    .replace("{PAGES_COUNT}", formData.pages_count);
}

async function generateWithClaude(prompt) {
  const message = await anthropic.messages.create({
    model: "claude-3-5-sonnet-20241022",
    max_tokens: 4096,
    messages: [
      {
        role: "user",
        content: prompt,
      },
    ],
  });

  const content = message.content[0];
  if (content.type !== "text") throw new Error("Unexpected response type");

  // Extract HTML from response
  let html = content.text;

  // If wrapped in markdown code block, extract it
  const htmlMatch = html.match(/\`\`\`html([\\s\\S]*?)\`\`\`/);
  if (htmlMatch) {
    html = htmlMatch[1].trim();
  }

  return html;
}

async function generateWithGroq(prompt) {
  const response = await fetch("https://api.groq.com/openai/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: \`Bearer \${Deno.env.get("GROQ_API_KEY")}\`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "mixtral-8x7b-32768",
      messages: [
        {
          role: "user",
          content: prompt,
        },
      ],
      max_tokens: 4096,
    }),
  });

  const data = await response.json();

  if (data.error) throw new Error(data.error.message);

  let html = data.choices[0].message.content;

  // Extract HTML from markdown if needed
  const htmlMatch = html.match(/\`\`\`html([\\s\\S]*?)\`\`\`/);
  if (htmlMatch) {
    html = htmlMatch[1].trim();
  }

  return html;
}

function capitalizeWord(word) {
  return word.charAt(0).toUpperCase() + word.slice(1);
}
`;

// Color Configuration (for reference in prompts)
const COLOR_CONFIG = {
  warm: {
    orange: { hex: "#FF6B35", name: "Orange", accent: "navy" },
    red: { hex: "#E63946", name: "Red", accent: "gold" },
    pink: { hex: "#FF006E", name: "Pink", accent: "purple" },
    coral: { hex: "#FF7F50", name: "Coral", accent: "teal" },
    gold: { hex: "#FFD700", name: "Gold", accent: "navy" },
  },
  cool: {
    blue: { hex: "#0066CC", name: "Blue", accent: "cyan" },
    navy: { hex: "#001F3F", name: "Navy", accent: "gold" },
    cyan: { hex: "#00D9FF", name: "Cyan", accent: "navy" },
    teal: { hex: "#20B2AA", name: "Teal", accent: "coral" },
    purple: { hex: "#9D4EDD", name: "Purple", accent: "gold" },
  },
  natural: {
    green: { hex: "#2D6A4F", name: "Green", accent: "sage" },
    sage: { hex: "#9CAF88", name: "Sage", accent: "teal" },
    brown: { hex: "#8B4513", name: "Brown", accent: "cream" },
    charcoal: { hex: "#36454F", name: "Charcoal", accent: "cyan" },
    taupe: { hex: "#B38B6D", name: "Taupe", accent: "gold" },
  },
  vibrant: {
    magenta: { hex: "#FF10F0", name: "Magenta", accent: "navy" },
    lime: { hex: "#00FF00", name: "Lime", accent: "navy" },
    indigo: { hex: "#4B0082", name: "Indigo", accent: "gold" },
  },
};

// Export
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    CLAUDE_WEBSITE_PROMPT,
    GROQ_WEBSITE_PROMPT,
    EDGE_FUNCTION_HANDLER,
    COLOR_CONFIG,
  };
}
`;

// Save to file
const fs = require("fs");
fs.writeFileSync(
  "/home/claude/website-builder-deploy/ai-prompts.js",
  CLAUDE_WEBSITE_PROMPT
);
