window.EInvoiceEngine = {
  async process(billData, billItems, shop) {
    if (!shop || !shop.enable_einvoicing) return { status: 'none' };
    if (!billData.customer_gstin || billData.customer_gstin.trim().length < 15) return { status: 'none' };

    const payload = {
      Version: "1.1",
      TranDtls: { TaxSch: "GST", SupTyp: "B2B", RegRev: "N", IgstOnIntra: "N" },
      DocDtls: { Typ: "INV", No: billData.invoice_no, Dt: new Date(billData.invoice_date).toLocaleDateString('en-GB') },
      SellerDtls: { Gstin: shop.gstin, LglNm: shop.name || "Business", Addr1: shop.address || "Address", Loc: shop.city || "City", Pin: parseInt(shop.pincode) || 110001, Stcd: shop.state_code || "07" },
      BuyerDtls: { Gstin: billData.customer_gstin.toUpperCase(), LglNm: billData.customer_name || "Customer", Pos: shop.state_code || "07", Loc: "NA", Pin: 999999 },
      ItemList: billItems.map((item, index) => ({
        SlNo: String(index + 1), PrdDesc: item.item_name || item.nm, IsServc: (item.kind === 'service' || item.kind === 'room') ? "Y" : "N", HsnCd: item.hsn_code || "9983", Qty: item.qty || item.q, Unit: "NOS", UnitPrice: item.rate || item.r, TotAmt: item.line_total || parseFloat(item.tot), AssAmt: item.line_total || parseFloat(item.tot), GstRt: item.gst_rate || item.rate, CgstAmt: (item.gst_amount || item.lineGST) > 0 ? ((item.gst_amount || item.lineGST) / 2) : 0, SgstAmt: (item.gst_amount || item.lineGST) > 0 ? ((item.gst_amount || item.lineGST) / 2) : 0, IgstAmt: 0, TotItemVal: (item.line_total || parseFloat(item.tot)) + (item.gst_amount || item.lineGST || 0)
      })),
      ValDtls: { AssVal: billData.subtotal, CgstVal: billData.gst_amount / 2, SgstVal: billData.gst_amount / 2, IgstVal: 0, TotInvVal: billData.grand_total }
    };

    try {
      const { data: result, error } = await window._sb.functions.invoke('generate-irp', {
        body: { payload: payload, shop_id: shop.id }
      });
      if (error) throw new Error(error.message);
      if (result && result.success) return { status: 'generated', irn: result.data.Irn, ack_no: result.data.AckNo, ack_date: result.data.AckDt, signed_qr: result.data.SignedQRCode };
      return { status: 'failed', error: result.error || 'IRP Rejected' };
    } catch (err) {
      return { status: 'failed', error: err.message };
    }
  }
};
