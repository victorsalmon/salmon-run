import nodemailer from 'nodemailer';

export async function sendEmail(transportConfig, message) {
  const required = ['host', 'port', 'user', 'password'];
  for (const field of required) {
    if (!transportConfig[field]) {
      throw new Error(`sendEmail: missing required transport config field "${field}"`);
    }
  }
  if (!message.to) {
    throw new Error('sendEmail: missing required message field "to"');
  }
  if (!message.subject) {
    throw new Error('sendEmail: missing required message field "subject"');
  }

  const transporter = nodemailer.createTransport({
    host: transportConfig.host,
    port: transportConfig.port,
    secure: transportConfig.secure !== false,
    auth: {
      user: transportConfig.user,
      pass: transportConfig.password,
    },
    tls: transportConfig.tls || undefined,
  });

  const mailOptions = {
    from: transportConfig.from || transportConfig.user,
    to: message.to,
    subject: message.subject,
    text: message.text || '',
    html: message.html || undefined,
  };

  if (message.attachments && message.attachments.length > 0) {
    mailOptions.attachments = message.attachments.map((att) => {
      if (typeof att === 'string') {
        return { path: att };
      }
      return att;
    });
  }

  const info = await transporter.sendMail(mailOptions);
  transporter.close();
  return {
    messageId: info.messageId,
    accepted: info.accepted || [],
    rejected: info.rejected || [],
    response: info.response,
  };
}
