import 'dart:ui' as ui;

class TutorialScript {
  final String stepName;
  final Map<String, String> localizedText;

  TutorialScript({required this.stepName, required this.localizedText});

  String get text {
    final langCode = ui.PlatformDispatcher.instance.locale.languageCode;
    return localizedText[langCode] ?? localizedText['en'] ?? '';
  }

  static List<TutorialScript> get scripts => [
        TutorialScript(
          stepName: 'welcome',
          localizedText: {
            'en': "Welcome to Jan Sahayak. I am your visual assistant. Tap once to repeat, or twice to go to the next step.",
            'hi': "जन-सहायक में आपका स्वागत है। मैं आपका विज़ुअल असिस्टेंट हूँ। दोहराने के लिए एक बार टैप करें, या अगले चरण पर जाने के लिए दो बार टैप करें।",
            'mr': "जन-सहाय्यक मध्ये आपले स्वागत आहे. मी तुमचा व्हिज्युअल असिस्टंट आहे. पुन्हा ऐकण्यासाठी एकदा टॅप करा किंवा पुढच्या स्टेपवर जाण्यासाठी दोनदा टॅप करा.",
            'te': "జన-సహాయక్ కు స్వాగతం. నేను మీ విజువల్ అసిస్టెంట్. పునరావృతం చేయడానికి ఒకసారి ట్యాప్ చేయండి లేదా తదుపరి దశకు వెళ్లడానికి రెండుసార్లు ట్యాప్ చేయండి.",
          },
        ),
        TutorialScript(
          stepName: 'home_camera',
          localizedText: {
            'en': "This is the Home screen. Point your camera at anything you want to understand or annotate.",
            'hi': "यह होम स्क्रीन है। अपने कैमरे को किसी भी चीज़ की ओर घुमाएँ जिसे आप समझना चाहते हैं।",
            'mr': "ही होम स्क्रीन आहे. तुम्हाला जी गोष्ट समजून घ्यायची आहे तिच्याकडे तुमचा कॅमेरा धरा.",
            'te': "ఇది హోమ్ స్క్రీన్. మీరు అర్థం చేసుకోవాలనుకుంటున్న లేదా వివరించాలనుకుంటున్న దేనివైపైనా మీ కెమెరాను చూపండి.",
          },
        ),
        TutorialScript(
          stepName: 'main_orb',
          localizedText: {
            'en': "Hold the large orb in the center to ask a question. While holding, speak clearly. Release the orb to take the photo and get my response.",
            'hi': "प्रश्न पूछने के लिए बीच वाले बड़े ओरब को दबाकर रखें। दबाए रखते हुए साफ़ बोलें। फोटो खींचने और मेरा जवाब पाने के लिए ओरब को छोड़ दें।",
            'mr': "प्रश्न विचारण्यासाठी मध्यभागी असलेल्या मोठ्या बटणाला दाबून धरा. दाबून धरलेले असताना स्पष्ट बोला. फोटो काढण्यासाठी आणि माझे उत्तर मिळवण्यासाठी बटण सोडून द्या.",
            'te': "ప్రశ్న అడగడానికి మధ్యలో ఉన్న పెద్ద బటన్‌ను నొక్కి పట్టుకోండి. పట్టుకున్నప్పుడు స్పష్టంగా మాట్లాడండి. ఫోటో తీసి నా సమాధానం పొందడానికి బటన్‌ను వదిలేయండి.",
          },
        ),
        TutorialScript(
          stepName: 'flash_button',
          localizedText: {
            'en': "The flash button on the left helps you see in the dark. Tap it to toggle the light.",
            'hi': "बाईं ओर वाला फ्लैश बटन आपको अंधेरे में देखने में मदद करता है। लाइट चालू या बंद करने के लिए इसे टैप करें।",
            'mr': "डावीकडील फ्लॅश बटण तुम्हाला अंधारात पाहण्यास मदत करते. लाईट चालू किंवा बंद करण्यासाठी त्यावर टॅप करा.",
            'te': "ఎడమవైపు ఉన్న ఫ్లాష్ బటన్ మీకు చీకటిలో చూడటానికి సహాయపడుతుంది. లైట్‌ను ఆన్ లేదా ఆఫ్ చేయడానికి దాన్ని ట్యాప్ చేయండి.",
          },
        ),
        TutorialScript(
          stepName: 'flip_button',
          localizedText: {
            'en': "The flip button on the right switches between your front and back cameras.",
            'hi': "दाईं ओर वाला फ्लिप बटन आपके सामने और पीछे के कैमरों के बीच स्विच करता है।",
            'mr': "उजवीकडील फ्लिप बटण तुमचे समोरचे आणि मागील कॅमेरे बदलण्यास मदत करते.",
            'te': "కుడివైపున్న ఫ్లిప్ బటన్ మీ ఫ్రంట్ మరియు బ్యాక్ కెమెరాల మధ్య మారుస్తుంది.",
          },
        ),
        TutorialScript(
          stepName: 'history_tab',
          localizedText: {
            'en': "At the bottom, you can find the History tab. This is where all your past conversations are saved securely.",
            'hi': "नीचे की ओर, आप हिस्ट्री टैब पा सकते हैं। यहाँ आपकी पिछली सभी बातचीत सुरक्षित रूप से सहेजी जाती हैं।",
            'mr': "खाली तुम्हाला हिस्ट्री टॅब मिळेल. इथे तुमचे सर्व जुने संवाद सुरक्षितपणे जतन केले जातात.",
            'te': "క్రింద, మీరు హిస్టరీ ట్యాబ్‌ను చూడవచ్చు. ఇక్కడ మీ గత సంభాషణలన్నీ సురక్షితంగా సేవ్ చేయబడతాయి.",
          },
        ),
        TutorialScript(
          stepName: 'conversation',
          localizedText: {
            'en': "When we talk, I will show you images with highlights and explain them through audio. You can always ask follow-up questions by holding the mic icon.",
            'hi': "जब हम बात करेंगे, तो मैं आपको फोटो में हाइलाइट्स दिखाऊंगा और ऑडियो के ज़रिए उन्हें समझाऊंगा। आप माइक आइकन दबाकर और भी सवाल पूछ सकते हैं।",
            'mr': "जेव्हा आपण संवाद साधू, तेव्हा मी तुम्हाला फोटोंमध्ये हायलाईट्स दाखवीन आणि ऑडिओद्वारे ते समजावून सांगेन. तुम्ही माइक आयकॉन दाबून अधिक प्रश्न विचारू शकता.",
            'te': "మనం మాట్లాడేటప్పుడు, నేను మీకు ముఖ్యాంశాలతో కూడిన చిత్రాలను చూపిస్తాను మరియు ఆడియో ద్వారా వాటిని వివరిస్తాను. మీరు మైక్ చిహ్నాన్ని పట్టుకోవడం ద్వారా ఎప్పుడైనా తదుపరి ప్రశ్నలను అడగవచ్చు.",
          },
        ),
        TutorialScript(
          stepName: 'finish',
          localizedText: {
            'en': "That's it! You are ready to use Jan Sahayak. Double tap one last time to finish the tutorial.",
            'hi': "बस इतना ही! अब आप जन-सहायक इस्तेमाल करने के लिए तैयार हैं। ट्यूटोरियल समाप्त करने के लिए आखिरी बार दो बार टैप करें।",
            'mr': "इतकेच! आता तुम्ही जन-सहाय्यक वापरण्यासाठी तयार आहात. ट्यूटोरियल संपवण्यासाठी शेवटच्या वेळी दोनदा टॅप करा.",
            'te': "అంతే! మీరు జన్-సహాయక్ ఉపయోగించడానికి సిద్ధంగా ఉన్నారు. ట్యుటోరియల్‌ని ముగించడానికి చివరిసారిగా రెండుసార్లు ట్యాప్ చేయండి.",
          },
        ),
      ];
}
