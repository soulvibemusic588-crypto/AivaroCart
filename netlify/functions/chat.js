
exports.handler = async (event) => {
  const headers = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };

  if (event.httpMethod === "OPTIONS") {
    return { statusCode: 204, headers, body: "" };
  }

  if (event.httpMethod !== "POST") {
    return {
      statusCode: 405,
      headers,
      body: JSON.stringify({ error: "POST method required" }),
    };
  }

  try {
    const apiKey = process.env.GEMINI_API_KEY;

    if (!apiKey) {
      return {
        statusCode: 500,
        headers,
        body: JSON.stringify({ error: "AI is not configured yet." }),
      };
    }

    const input = JSON.parse(event.body || "{}");
    const message =
      typeof input.message === "string" ? input.message.trim() : "";

    if (!message || message.length > 4000) {
      return {
        statusCode: 400,
        headers,
        body: JSON.stringify({ error: "Enter a message under 4000 characters." }),
      };
    }

    const response = await fetch(
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "x-goog-api-key": apiKey,
        },
        body: JSON.stringify({
          contents: [{ parts: [{ text: message }] }],
          systemInstruction: {
            parts: [{
              text: "You are AivaroCart's helpful shopping assistant. Answer clearly and honestly. You do not have access to live products, stock, orders, payments, or admin records unless they are explicitly supplied by a trusted backend. Never invent those details or claim to perform an order, refund, or discount."
            }]
          }
        }),
      }
    );

    const data = await response.json();

    if (!response.ok) {
      return {
        statusCode: 502,
        headers,
        body: JSON.stringify({ error: "The AI provider request failed." }),
      };
    }

    const reply =
      data.candidates?.[0]?.content?.parts
        ?.map((part) => part.text || "")
        .join("") || "Sorry, I couldn't generate a reply.";

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ reply }),
    };
  } catch {
    return {
      statusCode: 400,
      headers,
      body: JSON.stringify({ error: "Invalid request or connection problem." }),
    };
  }
};
